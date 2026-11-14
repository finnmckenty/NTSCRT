//! The VCR's signal path on the GPU (vcr.wgsl): a port of the Mac's
//! `VcrStage.swift`. Each active line is recorded as VHS records it —
//! luminance as FM after pre-emphasis and clipping, chroma heterodyned to
//! 629 kHz under it — and played back through the tape and the heads
//! (spacing and gap losses, noise) and the deck's electronics (FM
//! demodulation, de-emphasis, dropout detection and compensation,
//! color-under recovery with ACC, APC and a color killer). Numbers are NTSC
//! VHS SP (IEC 774-1, vhs-decode).

use super::deck::DeckParams;
use super::receiver::{timing as T, Raster};
use super::tape::{TapeGeometry, TapeParams};
use super::GlitchSettings;
use std::f64::consts::PI;

/// Samples per µs: 8 × the color subcarrier, 1820 a line.
pub fn sample_rate() -> f64 {
    8.0 * T::SUBCARRIER_MHZ
}
pub const SAMPLES_PER_LINE: u32 = 1820;
pub const SEGMENT: u32 = 16;
pub const SEGMENTS: u32 = SAMPLES_PER_LINE.div_ceil(SEGMENT);
pub const SYNC_TIP_MHZ: f64 = 3.4;
/// Color-under: 40 × the line rate.
pub fn color_under_mhz() -> f64 {
    40.0 / T::LINE
}
pub const CHROMA_LEVEL: f32 = 0.55;
/// Head and preamp noise per sample (carrier = 1): about 34 dB across the
/// FM band, demodulating to a new SP tape's 44 dB luma S/N.
pub const NOISE: f32 = 0.022;
const EMPHASIS_ZERO_MHZ: f64 = 1.0 / (2.0 * PI * 1.3);
const EMPHASIS_POLE_MHZ: f64 = 5.0 / (2.0 * PI * 1.3);
const FM_BAND: (f64, f64) = (1.3, 6.6);
const LUMA_MHZ: f64 = 3.0;
const CHROMA_MHZ: f64 = 0.55;
pub const LEVELS: u32 = 64;
pub const REACH: u32 = 40;
pub const MAX_SPACING: f32 = 4.0;
pub const FM_REACH: u32 = 47;

/// Carrier-to-noise across the FM band with a carrier of 1.
pub fn carrier_to_noise_db() -> f64 {
    let band = (FM_BAND.1 - FM_BAND.0) / (sample_rate() / 2.0);
    10.0 * (0.5 / ((NOISE * NOISE) as f64 * band)).log10()
}

/// Playback amplitude of a carrier at `mhz` after spacing `d` µm and a gap
/// of `gap` µm.
pub fn channel_gain(mhz: f64, d: f64, gap: f64) -> f64 {
    let loss = (-2.0 * PI / TapeGeometry::WRITING_SPEED * d * mhz).exp();
    let x = PI * gap * mhz / TapeGeometry::WRITING_SPEED;
    loss * if x < 1e-6 { 1.0 } else { (x.sin() / x).abs() }
}

/// Spacing-loss filters for one head: the Cauchy kernel of exp(−2πd/λ),
/// convolved with the gap's aperture, over spacing 0–4 µm.
pub fn bank(gap: f32) -> Vec<f32> {
    let taps = (2 * REACH + 1) as usize;
    let mut out = vec![0.0f32; LEVELS as usize * taps];
    let per_us = sample_rate();
    let half = (gap as f64 / TapeGeometry::WRITING_SPEED * per_us / 2.0).max(0.5);
    for i in 0..LEVELS as usize {
        let t = i as f64 / (LEVELS - 1) as f64;
        let d = MAX_SPACING as f64 * t * t;
        let c = (d / TapeGeometry::WRITING_SPEED * per_us).max(1e-4);
        for k in -(REACH as i64)..=REACH as i64 {
            let kd = k as f64;
            let w = (((kd + half) / c).atan() - ((kd - half) / c).atan()) / (2.0 * PI * half);
            out[i * taps + (k + REACH as i64) as usize] = w as f32;
        }
    }
    out
}

/// The FM band's analytic band-pass (Kaiser-windowed).
pub fn fm_band_taps() -> Vec<[f32; 2]> {
    let (f1, f2) = FM_BAND;
    let beta = 6.0;
    let bessel0 = |x: f64| {
        let (mut sum, mut term) = (1.0, 1.0);
        for k in 1..30 {
            term *= (x / (2.0 * k as f64)) * (x / (2.0 * k as f64));
            sum += term;
        }
        sum
    };
    (-(FM_REACH as i64)..=FM_REACH as i64)
        .map(|k| {
            let kd = k as f64;
            let (w1, w2) = (2.0 * PI * f1 / sample_rate(), 2.0 * PI * f2 / sample_rate());
            let (re, im) = if k == 0 {
                ((w2 - w1) / (2.0 * PI), 0.0)
            } else {
                (((w2 * kd).sin() - (w1 * kd).sin()) / (2.0 * PI * kd), ((w1 * kd).cos() - (w2 * kd).cos()) / (2.0 * PI * kd))
            };
            let r = kd / FM_REACH as f64;
            let win = bessel0(beta * (1.0 - r * r).sqrt()) / bessel0(beta);
            [(2.0 * re * win) as f32, (2.0 * im * win) as f32]
        })
        .collect()
}

fn low_pass(mhz: f64) -> [f32; 5] {
    let k = (PI * mhz / sample_rate()).tan();
    let s2 = 2f64.sqrt();
    let norm = 1.0 / (1.0 + s2 * k + k * k);
    let b0 = k * k * norm;
    [b0 as f32, (2.0 * b0) as f32, b0 as f32, (2.0 * (k * k - 1.0) * norm) as f32, ((1.0 - s2 * k + k * k) * norm) as f32]
}

fn shelf(zero: f64, pole: f64) -> [f32; 3] {
    let a = 2.0 * sample_rate() / (2.0 * PI * zero);
    let b = 2.0 * sample_rate() / (2.0 * PI * pole);
    [((1.0 + a) / (1.0 + b)) as f32, ((1.0 - a) / (1.0 + b)) as f32, ((1.0 - b) / (1.0 + b)) as f32]
}

/// One active line as the VCR reads it (mirrors the GPU struct, 32 bytes).
#[repr(C)]
#[derive(Clone, Copy, Debug, Default, PartialEq, bytemuck::Pod, bytemuck::Zeroable)]
pub struct VcrLine {
    pub origin_base: i32,
    pub origin_offset: f32,
    pub along0: f32,
    /// Spacing the head brings (worn tip, dirt, debris), µm.
    pub spacing: f32,
    pub grease: f32,
    /// Read efficiency × how much of its track the head is on.
    pub gain: f32,
    pub head: u32,
    pub pad: f32,
}

/// What the VCR needs for one displayed field.
#[derive(Clone, Debug, PartialEq)]
pub struct VcrFieldPlan {
    pub lines: Vec<VcrLine>,
    pub tape: TapeParams,
    pub deck: DeckParams,
}

/// The uniforms (mirrors `VcrU` in vcr.wgsl: 12 u32, then 44 f32).
fn uniforms(plan: &VcrFieldPlan, s: &GlitchSettings, raster: &Raster, width: u32, rows: u32, field: u32) -> Vec<u8> {
    let t = &plan.tape;
    let em = shelf(EMPHASIS_ZERO_MHZ, EMPHASIS_POLE_MHZ);
    let de = shelf(EMPHASIS_POLE_MHZ, EMPHASIS_ZERO_MHZ);
    let lp = low_pass(LUMA_MHZ);
    let cp = low_pass(CHROMA_MHZ);
    let a = TapeGeometry::angle();
    let u32s: [u32; 12] = [
        rows,
        SAMPLES_PER_LINE,
        SEGMENTS,
        width,
        t.seed,
        field,
        s.flag("dropout_compensation") as u32,
        FM_REACH,
        LEVELS,
        REACH,
        raster.total_lines() as u32,
        0,
    ];
    let f32s: [f32; 44] = [
        (T::ACTIVE_LENGTH / width as f64) as f32,
        (1.0 / sample_rate()) as f32,
        T::LINE as f32,
        TapeGeometry::line_length() as f32,
        TapeGeometry::track_pitch() as f32,
        a.cos() as f32,
        a.sin() as f32,
        TapeGeometry::TRACK_START as f32,
        NOISE,
        CHROMA_LEVEL,
        (2.0 * PI * color_under_mhz() / sample_rate()) as f32,
        MAX_SPACING,
        em[0],
        em[1],
        em[2],
        226.0,
        de[0],
        de[1],
        de[2],
        -82.0,
        lp[0],
        lp[1],
        lp[2],
        lp[3],
        lp[4],
        cp[0],
        cp[1],
        cp[2],
        cp[3],
        cp[4],
        0.16,
        0.25,
        t.wear,
        t.dropouts,
        t.scratches,
        t.creases,
        t.edge,
        t.mold,
        t.vaseline,
        t.remanence(),
        t.roughness(),
        t.pinhole_chance(),
        t.flake_chance(),
        T::BURST_AMPLITUDE as f32,
    ];
    let mut out = Vec::with_capacity(224);
    u32s.iter().for_each(|v| out.extend_from_slice(&v.to_le_bytes()));
    f32s.iter().for_each(|v| out.extend_from_slice(&v.to_le_bytes()));
    out
}

/// The eight passes, compiled once, and their working buffers.
pub struct VcrGpu {
    pipes: Vec<(&'static str, wgpu::ComputePipeline, &'static [u32])>,
    fm_taps: wgpu::Buffer,
    bank: std::sync::Mutex<Option<([f32; 2], wgpu::Buffer)>>,
}

/// Each kernel and the bindings it uses (only those: WebGPU allows 8
/// storage buffers per stage).
const KERNELS: [(&str, &[u32]); 8] = [
    ("vcr_record", &[0, 2, 13]),
    ("vcr_tape", &[0, 1, 3]),
    ("vcr_magnet", &[0, 2, 3, 4]),
    ("vcr_play", &[0, 1, 4, 5, 11]),
    ("vcr_fmband", &[0, 5, 6, 12]),
    ("vcr_line", &[0, 5, 6, 7, 8, 9]),
    ("vcr_acc", &[0, 9, 10]),
    ("vcr_out", &[0, 7, 8, 10, 14]),
];

impl VcrGpu {
    pub fn new(device: &wgpu::Device) -> Self {
        let module = device.create_shader_module(wgpu::ShaderModuleDescriptor {
            label: Some("vcr"),
            source: wgpu::ShaderSource::Wgsl(include_str!("vcr.wgsl").into()),
        });
        let pipes = KERNELS
            .iter()
            .map(|(name, binds)| {
                let p = device.create_compute_pipeline(&wgpu::ComputePipelineDescriptor {
                    label: Some(name),
                    layout: None,
                    module: &module,
                    entry_point: Some(name),
                    compilation_options: Default::default(),
                    cache: None,
                });
                (*name, p, *binds)
            })
            .collect();
        let taps = fm_band_taps();
        let fm_taps = device.create_buffer(&wgpu::BufferDescriptor {
            label: Some("vcr fm taps"),
            size: (taps.len() * 8) as u64,
            usage: wgpu::BufferUsages::STORAGE | wgpu::BufferUsages::COPY_DST,
            mapped_at_creation: true,
        });
        fm_taps.slice(..).get_mapped_range_mut().copy_from_slice(bytemuck::cast_slice(&taps));
        fm_taps.unmap();
        Self { pipes, fm_taps, bank: Default::default() }
    }

    /// Play `input` (one row per active line) from tape into `output`
    /// (Rgba16Float, same size).
    #[allow(clippy::too_many_arguments)]
    pub fn encode(&self, device: &wgpu::Device, queue: &wgpu::Queue, enc: &mut wgpu::CommandEncoder, input: &wgpu::Texture, output: &wgpu::Texture, plan: &VcrFieldPlan, settings: &GlitchSettings, raster: &Raster, field: u32) {
        let rows = plan.lines.len().min(input.height() as usize) as u32;
        if rows == 0 {
            return;
        }
        let n = SAMPLES_PER_LINE as u64;
        let samples = rows as u64 * n;
        let width = input.width();
        let make = |size: u64| device.create_buffer(&wgpu::BufferDescriptor { label: None, size: size.max(16), usage: wgpu::BufferUsages::STORAGE, mapped_at_creation: false });
        let upload = |data: &[u8], usage: wgpu::BufferUsages| {
            let b = device.create_buffer(&wgpu::BufferDescriptor { label: None, size: data.len().max(16) as u64, usage: usage | wgpu::BufferUsages::COPY_DST, mapped_at_creation: false });
            queue.write_buffer(&b, 0, data);
            b
        };
        let gaps = [plan.deck.gap(0), plan.deck.gap(1)];
        let bank = {
            let mut cache = self.bank.lock().expect("bank");
            if cache.as_ref().map(|c| c.0) != Some(gaps) {
                let data: Vec<f32> = bank(gaps[0]).into_iter().chain(bank(gaps[1])).collect();
                *cache = Some((gaps, upload(bytemuck::cast_slice(&data), wgpu::BufferUsages::STORAGE)));
            }
            cache.as_ref().expect("bank").1.clone()
        };
        let ubuf = upload(&uniforms(plan, settings, raster, width, rows, field), wgpu::BufferUsages::UNIFORM);
        let lines = upload(bytemuck::cast_slice(&plan.lines[..rows as usize]), wgpu::BufferUsages::STORAGE);
        let rf = make(samples * 4);
        let seg = make(rows as u64 * SEGMENTS as u64 * 8);
        let mag = make(samples * 8);
        let pb = make(samples * 4);
        let z = make(samples * 8);
        let luma = make(samples * 4);
        let chroma = make(samples * 8);
        let burst = make(rows as u64 * 8);
        let color = make(rows as u64 * 16);
        let in_view = input.create_view(&Default::default());
        let out_view = output.create_view(&Default::default());
        let resource = |b: u32| -> wgpu::BindingResource<'_> {
            match b {
                0 => ubuf.as_entire_binding(),
                1 => lines.as_entire_binding(),
                2 => rf.as_entire_binding(),
                3 => seg.as_entire_binding(),
                4 => mag.as_entire_binding(),
                5 => pb.as_entire_binding(),
                6 => z.as_entire_binding(),
                7 => luma.as_entire_binding(),
                8 => chroma.as_entire_binding(),
                9 => burst.as_entire_binding(),
                10 => color.as_entire_binding(),
                11 => bank.as_entire_binding(),
                12 => self.fm_taps.as_entire_binding(),
                13 => wgpu::BindingResource::TextureView(&in_view),
                _ => wgpu::BindingResource::TextureView(&out_view),
            }
        };
        let groups: Vec<wgpu::BindGroup> = self
            .pipes
            .iter()
            .map(|(name, p, binds)| {
                let entries: Vec<wgpu::BindGroupEntry> = binds.iter().map(|b| wgpu::BindGroupEntry { binding: *b, resource: resource(*b) }).collect();
                device.create_bind_group(&wgpu::BindGroupDescriptor { label: Some(name), layout: &p.get_bind_group_layout(0), entries: &entries })
            })
            .collect();
        let mut pass = enc.begin_compute_pass(&wgpu::ComputePassDescriptor { label: Some("vcr"), timestamp_writes: None });
        let per_row = rows.div_ceil(64);
        let dispatch = [(per_row, 1), (SEGMENTS.div_ceil(64), rows), (SAMPLES_PER_LINE.div_ceil(64), rows), (SAMPLES_PER_LINE.div_ceil(64), rows), (SAMPLES_PER_LINE.div_ceil(64), rows), (per_row, 1), (1, 1), (width.div_ceil(64), rows)];
        for (i, ((_, p, _), g)) in self.pipes.iter().zip(&groups).enumerate() {
            pass.set_pipeline(p);
            pass.set_bind_group(0, g, &[]);
            pass.dispatch_workgroups(dispatch[i].0, dispatch[i].1, 1);
        }
    }
}
