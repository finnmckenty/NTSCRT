//! The Glitch stage on the GPU (glitch.wgsl), fed as the Mac's
//! `GlitchStage.encode` feeds its Metal kernels; and the receiver's clock
//! (`Renderer`, the Mac's `GlitchRenderer`): moving forward a little
//! continues the simulation, jumping or retuning while standing still
//! re-simulates, so a given moment always looks the same.

use std::f64::consts::PI;
use std::sync::Arc;

use super::params::GlitchSettings;
use super::receiver::{draw_constants, timing as T, Dropout, FieldPlan, Raster, Simulator, Snapshot};

/// How glitch settings vary over time (keyframes), for re-simulating a
/// stretch of history exactly.
#[derive(Clone)]
pub struct GlitchHistory {
    pub frame_duration: f64,
    /// Changes whenever the history would, so checkpoints from one history
    /// are never reused for another.
    pub id: u64,
    pub settings_at: Arc<dyn Fn(f64) -> GlitchSettings + Send + Sync>,
}

impl std::fmt::Debug for GlitchHistory {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "GlitchHistory {{ frame_duration: {}, id: {} }}", self.frame_duration, self.id)
    }
}

impl PartialEq for GlitchHistory {
    fn eq(&self, other: &Self) -> bool {
        self.id == other.id && self.frame_duration == other.frame_duration
    }
}

/// The stage for one frame: the knobs, the receiver's clock (seconds), and
/// with keyframes how the knobs got here.
#[derive(Clone, Debug, PartialEq)]
pub struct GlitchFrame {
    pub settings: GlitchSettings,
    pub time: f64,
    pub history: Option<GlitchHistory>,
}

#[derive(Clone, Debug, PartialEq)]
enum CheckpointKey {
    Constant(Vec<(String, f64)>),
    History(u64, u64),
}

#[derive(Default)]
pub struct Renderer {
    sim: Option<Simulator>,
    last_settings: Option<GlitchSettings>,
    checkpoints: Vec<Snapshot>,
    key: Option<CheckpointKey>,
}

impl Renderer {
    /// Forward jumps longer than this re-simulate instead of stepping.
    pub const MAX_STEP: f64 = 1.0;

    /// Bring the receiver to `frame.time` and return the field it displays.
    pub fn plan(&mut self, raster: Raster, frame: &GlitchFrame) -> FieldPlan {
        let mut fresh = false;
        if self.sim.as_ref().map(|s| s.raster) != Some(raster) {
            self.sim = Some(Simulator::new(raster));
            fresh = true;
            self.checkpoints.clear();
            self.key = None;
        }
        let time = frame.time;
        let settings = &frame.settings;
        let sim_time = self.sim.as_ref().expect("sim").time();
        let line_time = 1.0 / (raster.total_lines() as f64 * T::FIELD_RATE);
        let standing_still = (time - sim_time).abs() <= 2.0 * line_time;
        let jumped = time < sim_time - 2.0 * line_time || time - sim_time > Self::MAX_STEP;
        let retuned = standing_still && self.last_settings.as_ref().is_some_and(|l| l.timing() != settings.timing());
        if fresh || jumped || retuned {
            self.resimulate(time, settings, frame.history.as_ref());
        } else {
            let sim = self.sim.as_mut().expect("sim");
            sim.advance(time, settings);
            // Playing on under constant settings extends the checkpoints.
            if self.key == Some(CheckpointKey::Constant(settings.timing()))
                && sim.time() >= self.checkpoints.last().map_or(0.0, |c| c.time) + 1.0
            {
                self.checkpoints.push(sim.snapshot());
            }
        }
        self.last_settings = Some(settings.clone());
        self.sim.as_ref().expect("sim").plan()
    }

    fn resimulate(&mut self, time: f64, settings: &GlitchSettings, history: Option<&GlitchHistory>) {
        let key = match history {
            Some(h) => CheckpointKey::History(h.id, h.frame_duration.to_bits()),
            None => CheckpointKey::Constant(settings.timing()),
        };
        if Some(&key) != self.key.as_ref() {
            self.checkpoints.clear();
            self.key = Some(key);
        }
        let resume = self.checkpoints.iter().rev().find(|c| c.time <= time).cloned();
        let sim = self.sim.as_mut().expect("sim");
        if let Some(h) = history {
            let checkpoints = &mut self.checkpoints;
            let mut keep = |snap: Snapshot| {
                if snap.time > checkpoints.last().map_or(-1.0, |c| c.time) {
                    checkpoints.push(snap);
                }
            };
            let settings_at = h.settings_at.clone();
            sim.resimulate(time, h.frame_duration, &move |t| settings_at(t), resume.as_ref(), Some(&mut keep));
            return;
        }
        // Constant settings: the state at any moment is a function of time
        // alone, so checkpoints can sit on whole seconds.
        match &resume {
            Some(r) => sim.restore(r),
            None => sim.reset(),
        }
        let mut next = (resume.as_ref().map_or(0.0, |r| r.time) + 1.0).floor().max(1.0);
        while next < time {
            sim.advance(next, settings);
            if sim.time() > self.checkpoints.last().map_or(-1.0, |c| c.time) {
                self.checkpoints.push(sim.snapshot());
            }
            next += 1.0;
        }
        sim.advance(time, settings);
    }
}

/// The three passes, compiled once.
pub struct Gpu {
    layout: wgpu::BindGroupLayout,
    gate: wgpu::ComputePipeline,
    chroma: wgpu::ComputePipeline,
    compose: wgpu::ComputePipeline,
}

impl Gpu {
    pub fn new(device: &wgpu::Device) -> Self {
        let module = device.create_shader_module(wgpu::ShaderModuleDescriptor {
            label: Some("glitch"),
            source: wgpu::ShaderSource::Wgsl(include_str!("glitch.wgsl").into()),
        });
        let buffer = |binding: u32, ty: wgpu::BufferBindingType| wgpu::BindGroupLayoutEntry {
            binding,
            visibility: wgpu::ShaderStages::COMPUTE,
            ty: wgpu::BindingType::Buffer { ty, has_dynamic_offset: false, min_binding_size: None },
            count: None,
        };
        let layout = device.create_bind_group_layout(&wgpu::BindGroupLayoutDescriptor {
            label: Some("glitch"),
            entries: &[
                buffer(0, wgpu::BufferBindingType::Uniform),
                buffer(1, wgpu::BufferBindingType::Storage { read_only: true }),
                buffer(2, wgpu::BufferBindingType::Storage { read_only: false }),
                buffer(3, wgpu::BufferBindingType::Storage { read_only: false }),
                buffer(4, wgpu::BufferBindingType::Storage { read_only: true }),
                wgpu::BindGroupLayoutEntry {
                    binding: 5,
                    visibility: wgpu::ShaderStages::COMPUTE,
                    ty: wgpu::BindingType::Texture {
                        sample_type: wgpu::TextureSampleType::Float { filterable: false },
                        view_dimension: wgpu::TextureViewDimension::D2,
                        multisampled: false,
                    },
                    count: None,
                },
                wgpu::BindGroupLayoutEntry {
                    binding: 6,
                    visibility: wgpu::ShaderStages::COMPUTE,
                    ty: wgpu::BindingType::StorageTexture {
                        access: wgpu::StorageTextureAccess::WriteOnly,
                        format: wgpu::TextureFormat::Rgba8Unorm,
                        view_dimension: wgpu::TextureViewDimension::D2,
                    },
                    count: None,
                },
            ],
        });
        let pl = device.create_pipeline_layout(&wgpu::PipelineLayoutDescriptor { label: Some("glitch"), bind_group_layouts: &[&layout], immediate_size: 0 });
        let pipe = |entry: &str| {
            device.create_compute_pipeline(&wgpu::ComputePipelineDescriptor {
                label: Some(entry),
                layout: Some(&pl),
                module: &module,
                entry_point: Some(entry),
                compilation_options: Default::default(),
                cache: None,
            })
        };
        Self { gate: pipe("glitch_gate"), chroma: pipe("glitch_chroma"), compose: pipe("glitch_compose"), layout }
    }

    /// Draw the field `plan` describes from `input` into `output` (same size).
    pub fn encode(&self, device: &wgpu::Device, queue: &wgpu::Queue, enc: &mut wgpu::CommandEncoder, input: &wgpu::Texture, output: &wgpu::Texture, plan: &FieldPlan) {
        let raster = plan.raster;
        let rows = &plan.rows;
        if rows.len() != input.height() as usize || rows.is_empty() {
            return;
        }
        let s = &plan.settings;
        let k = draw_constants(s, &raster);
        let width = input.width();
        let us_per_pixel = T::ACTIVE_LENGTH / width as f64;
        let ghost_delay = s.get("ghost_delay");
        let ghost_angle = -2.0 * PI * T::SUBCARRIER_MHZ * ghost_delay;
        let snap = |v: f32, target: f32| if (v - target).abs() < 1e-6 { target } else { v };
        let drop_count = plan.dropouts.len().min(64);
        let u32s: [u32; 16] = [
            width,
            raster.active_lines as u32,
            raster.vbi_lines as u32,
            raster.total_lines() as u32,
            raster.pre_eq_end as u32,
            raster.vsync_end as u32,
            raster.post_eq_end as u32,
            s.flag("closed_captions") as u32,
            plan.cc_bits,
            plan.field_index,
            0x9E3779B9,
            drop_count as u32,
            s.flag("dropout_compensation") as u32,
            ((0.38 / us_per_pixel).round() as u32).max(1),
            ((0.83 / us_per_pixel).round() as u32).max(1),
            plan.color_on as u32,
        ];
        let f32s: [f32; 16] = [
            us_per_pixel as f32,
            T::LINE as f32,
            s.get("ghost_level") as f32,
            ghost_delay as f32,
            ghost_angle.cos() as f32,
            ghost_angle.sin() as f32,
            s.get("brightness").clamp(0.0, 1.0) as f32,
            snap(plan.picture_gain, 1.0),
            (T::BURST_AMPLITUDE * k.agc) as f32,
            k.chroma_alpha as f32,
            k.acc_gamma as f32,
            k.killer_kappa as f32,
            snap(plan.chroma_phase, 0.0),
            snap(plan.chroma_gain, 1.0),
            snap(plan.killer, 1.0),
            0.45,
        ];
        let mut uniform: Vec<u8> = Vec::with_capacity(128);
        u32s.iter().for_each(|v| uniform.extend_from_slice(&v.to_le_bytes()));
        f32s.iter().for_each(|v| uniform.extend_from_slice(&v.to_le_bytes()));
        let mut drops: Vec<Dropout> = plan.dropouts.iter().take(64).copied().collect();
        if drops.is_empty() {
            drops.push(Dropout { field_line: -1, u_start: 0.0, u_length: 0.0, pad: 0.0 });
        }
        let buffer = |data: &[u8], usage: wgpu::BufferUsages| {
            let b = device.create_buffer(&wgpu::BufferDescriptor { label: None, size: data.len().max(16) as u64, usage: usage | wgpu::BufferUsages::COPY_DST, mapped_at_creation: false });
            queue.write_buffer(&b, 0, data);
            b
        };
        let ubuf = buffer(&uniform, wgpu::BufferUsages::UNIFORM);
        let rbuf = buffer(bytemuck::cast_slice(rows), wgpu::BufferUsages::STORAGE);
        let dbuf = buffer(bytemuck::cast_slice(&drops), wgpu::BufferUsages::STORAGE);
        let gate = device.create_buffer(&wgpu::BufferDescriptor { label: None, size: rows.len() as u64 * 8, usage: wgpu::BufferUsages::STORAGE, mapped_at_creation: false });
        let color = device.create_buffer(&wgpu::BufferDescriptor { label: None, size: rows.len() as u64 * 16, usage: wgpu::BufferUsages::STORAGE, mapped_at_creation: false });
        let bind = device.create_bind_group(&wgpu::BindGroupDescriptor {
            label: Some("glitch"),
            layout: &self.layout,
            entries: &[
                wgpu::BindGroupEntry { binding: 0, resource: ubuf.as_entire_binding() },
                wgpu::BindGroupEntry { binding: 1, resource: rbuf.as_entire_binding() },
                wgpu::BindGroupEntry { binding: 2, resource: gate.as_entire_binding() },
                wgpu::BindGroupEntry { binding: 3, resource: color.as_entire_binding() },
                wgpu::BindGroupEntry { binding: 4, resource: dbuf.as_entire_binding() },
                wgpu::BindGroupEntry { binding: 5, resource: wgpu::BindingResource::TextureView(&input.create_view(&Default::default())) },
                wgpu::BindGroupEntry { binding: 6, resource: wgpu::BindingResource::TextureView(&output.create_view(&Default::default())) },
            ],
        });
        let mut pass = enc.begin_compute_pass(&wgpu::ComputePassDescriptor { label: Some("glitch"), timestamp_writes: None });
        pass.set_bind_group(0, &bind, &[]);
        pass.set_pipeline(&self.gate);
        pass.dispatch_workgroups((rows.len() as u32).div_ceil(64), 1, 1);
        pass.set_pipeline(&self.chroma);
        pass.dispatch_workgroups(1, 1, 1);
        pass.set_pipeline(&self.compose);
        pass.dispatch_workgroups(width.div_ceil(8), input.height().div_ceil(8), 1);
    }
}
