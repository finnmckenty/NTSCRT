//! The Glitch stage on the GPU (glitch.wgsl), fed as the Mac's
//! `GlitchStage.encode` feeds its Metal kernels; and the receiver's clock
//! (`Renderer`, the Mac's `GlitchRenderer`): moving forward a little
//! continues the simulation, jumping or retuning while standing still
//! re-simulates, so a given moment always looks the same.

use std::f64::consts::PI;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};

use super::params::GlitchSettings;
use super::composite::{self, CompositeSignal};
use super::receiver::{draw_constants, timing as T, FieldPlan, Raster, Simulator, Snapshot};
use super::vcr::VcrGpu;

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

/// A re-run on a thread of its own (see `Renderer::background`).
struct Rerun {
    key: CheckpointKey,
    time: f64,
    raster: Raster,
    settings: GlitchSettings,
    /// The checkpoints it resumed from (kept with what it adds).
    kept: Vec<Snapshot>,
    cancel: Arc<AtomicBool>,
    result: Arc<Mutex<Option<(Simulator, Vec<Snapshot>)>>>,
}

#[derive(Default)]
pub struct Renderer {
    sim: Option<Simulator>,
    last_settings: Option<GlitchSettings>,
    checkpoints: Vec<Snapshot>,
    key: Option<CheckpointKey>,
    /// The preview turns this on: a long exact re-run (a VCR knob turned on
    /// a paused clip a minute in, a far scrub) happens on a thread of its
    /// own while the preview shows the knobs applied to the state it has;
    /// the next `plan` after it finishes picks it up (`rerun_landed` says
    /// when to ask). Exports leave it off — every frame they draw is exact.
    pub background: bool,
    rerun: Option<Rerun>,
    /// The time of the frame planned last, for telling how far playback
    /// moved while a re-run is in flight.
    last_time: Option<f64>,
}

impl Drop for Renderer {
    fn drop(&mut self) {
        self.cancel_rerun();
    }
}

impl Renderer {
    /// Forward jumps longer than this re-simulate instead of stepping.
    pub const MAX_STEP: f64 = 1.0;
    /// Re-runs longer than this (simulated seconds from where one can
    /// resume) go to a thread of their own when `background` is on. A
    /// second of simulation is ~35 ms; a minute is ~2 s.
    pub const BACKGROUND_ABOVE: f64 = 1.5;

    /// A background re-run is on its way.
    pub fn rerun_pending(&self) -> bool {
        self.rerun.is_some()
    }

    /// A background re-run has finished: the next `plan` uses it.
    pub fn rerun_landed(&self) -> bool {
        self.rerun.as_ref().is_some_and(|r| r.result.lock().map(|g| g.is_some()).unwrap_or(false))
    }

    /// If a background re-run has finished, take it over (the next `plan`
    /// starts from it) and say so — once.
    pub fn take_landed(&mut self) -> bool {
        if !self.rerun_landed() {
            return false;
        }
        self.adopt_rerun();
        true
    }

    /// Forget the simulation: the next frame starts from a freshly simulated
    /// set at its time, as if these settings had always been on (a new look
    /// mustn't inherit the last one's rolling picture or lost tracking).
    pub fn restart(&mut self) {
        self.cancel_rerun();
        self.sim = None;
        self.checkpoints.clear();
        self.key = None;
        self.last_settings = None;
        self.last_time = None;
    }

    fn cancel_rerun(&mut self) {
        if let Some(r) = self.rerun.take() {
            r.cancel.store(true, Ordering::Relaxed);
        }
    }

    /// Take a finished background re-run's simulation and checkpoints.
    fn adopt_rerun(&mut self) {
        let Some(r) = self.rerun.as_ref() else { return };
        let Some((sim, taken)) = r.result.lock().ok().and_then(|mut g| g.take()) else { return };
        let r = self.rerun.take().expect("checked");
        if self.sim.as_ref().map(|s| s.raster) != Some(r.raster) {
            return;
        }
        let mut all = r.kept;
        for snap in taken {
            if snap.time > all.last().map_or(f64::NEG_INFINITY, |c| c.time) {
                all.push(snap);
            }
        }
        self.sim = Some(sim);
        self.checkpoints = all;
        self.key = Some(r.key);
        self.last_settings = Some(r.settings);
    }

    /// Bring the receiver to `frame.time` and return the field it displays.
    pub fn plan(&mut self, raster: Raster, frame: &GlitchFrame) -> FieldPlan {
        self.adopt_rerun();
        let mut fresh = false;
        if self.sim.as_ref().map(|s| s.raster) != Some(raster) {
            self.cancel_rerun();
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
        let past = if standing_still { None } else { frame.history.as_ref() };
        if fresh || jumped || retuned {
            let h = frame.history.as_ref();
            let key = match h {
                Some(h) => CheckpointKey::History(h.id, h.frame_duration.to_bits()),
                None => CheckpointKey::Constant(settings.timing()),
            };
            let resume_at =
                if Some(&key) == self.key.as_ref() { self.checkpoints.iter().rev().find(|c| c.time <= time).map(|c| c.time) } else { None };
            let span = time - resume_at.unwrap_or(-Simulator::WARMUP);
            if self.background && span > Self::BACKGROUND_ABOVE {
                let on_its_way = self.rerun.as_ref().is_some_and(|r| r.key == key && r.raster == raster && r.time <= time + 2.0 * line_time);
                if on_its_way {
                    // Already on its way to here, or to a moment before it
                    // (playing on, scrubbing forward); from where it lands,
                    // the rest is a short step. Until then the state we have
                    // runs on by as much as the playhead moved, so a playing
                    // picture doesn't stand still meanwhile.
                    if let Some(last) = self.last_time.filter(|last| time > *last && time - *last <= Self::MAX_STEP) {
                        let sim = self.sim.as_mut().expect("sim");
                        let to = sim.time() + (time - last);
                        sim.advance(to, settings);
                    }
                } else {
                    self.show_meanwhile(time, settings, retuned, fresh);
                    self.start_rerun(key, time, settings, h.cloned(), raster);
                }
            } else {
                self.cancel_rerun();
                self.resimulate(time, settings, h);
            }
        } else if let Some(h) = past.filter(|h| self.key == Some(CheckpointKey::History(h.id, h.frame_duration.to_bits()))) {
            // A short step forward through keyframed knobs (playback, or a
            // scrub of under a second): run it frame by frame through the
            // keyframes, exactly as the re-run from zero would, so a moment
            // looks the same however the playhead got there.
            let sim = self.sim.as_mut().expect("sim");
            let resume = sim.snapshot();
            let settings_at = h.settings_at.clone();
            sim.resimulate(time, h.frame_duration, &move |t| settings_at(t), Some(&resume), None);
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
        self.last_time = Some(time);
        self.sim.as_ref().expect("sim").plan()
    }

    /// While a background re-run works: the knobs applied to the state the
    /// simulation has (a knob turned on a paused frame), a checkpoint within
    /// a second of a jump stepped on to it, or a fresh set's first moment.
    fn show_meanwhile(&mut self, time: f64, settings: &GlitchSettings, retuned: bool, fresh: bool) {
        let near = self.checkpoints.iter().rev().find(|c| c.time <= time && time - c.time <= Self::MAX_STEP).cloned();
        let sim = self.sim.as_mut().expect("sim");
        if retuned {
            let t = sim.time();
            sim.advance(t, settings);
        } else if let Some(c) = near {
            sim.restore(&c);
            sim.advance(time, settings);
        } else if fresh {
            sim.advance(0.0, settings);
        }
    }

    /// The exact re-run on a fresh simulator on a thread of its own.
    fn start_rerun(&mut self, key: CheckpointKey, time: f64, settings: &GlitchSettings, history: Option<GlitchHistory>, raster: Raster) {
        self.cancel_rerun();
        let kept_all = if Some(&key) == self.key.as_ref() { self.checkpoints.clone() } else { Vec::new() };
        let resume = kept_all.iter().rev().find(|c| c.time <= time).cloned();
        let kept: Vec<Snapshot> = kept_all.into_iter().filter(|c| resume.as_ref().is_some_and(|r| c.time <= r.time)).collect();
        let cancel = Arc::new(AtomicBool::new(false));
        let result = Arc::new(Mutex::new(None));
        let (stop, out, constant) = (cancel.clone(), result.clone(), settings.clone());
        std::thread::spawn(move || {
            let cancelled = || stop.load(Ordering::Relaxed);
            let mut sim = Simulator::new(raster);
            let mut taken = Vec::new();
            if let Some(h) = history {
                let settings_at = h.settings_at.clone();
                let mut keep = |snap: Snapshot| taken.push(snap);
                sim.resimulate_unless(time, h.frame_duration, &move |t| settings_at(t), resume.as_ref(), Some(&mut keep), &cancelled);
            } else {
                match &resume {
                    Some(r) => sim.restore(r),
                    None => {
                        sim.advance(0.0, &constant);
                        taken.push(sim.snapshot_at(Some(0.0)));
                    }
                }
                let mut next = (resume.as_ref().map_or(0.0, |r| r.time) + 1.0).floor().max(1.0);
                while next < time && !cancelled() {
                    sim.advance(next, &constant);
                    taken.push(sim.snapshot());
                    next += 1.0;
                }
                if !cancelled() {
                    sim.advance(time, &constant);
                }
            }
            if !cancelled() {
                if let Ok(mut g) = out.lock() {
                    *g = Some((sim, taken));
                }
            }
        });
        self.rerun = Some(Rerun { key, time, raster, settings: settings.clone(), kept, cancel, result });
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
        // alone, so checkpoints can sit on whole seconds — time zero among
        // them, the warmed-up set a looping clip returns to on every pass
        // (without it each loop re-ran the two-second warm-up).
        match &resume {
            Some(r) => sim.restore(r),
            None => {
                sim.reset();
                sim.advance(0.0, settings);
                if self.checkpoints.is_empty() {
                    self.checkpoints.push(sim.snapshot_at(Some(0.0)));
                }
            }
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

/// The three passes, compiled once, and the VCR's ahead of them.
pub struct Gpu {
    layout: wgpu::BindGroupLayout,
    gate: wgpu::ComputePipeline,
    chroma: wgpu::ComputePipeline,
    compose: wgpu::ComputePipeline,
    vcr: VcrGpu,
    vcr_output: std::sync::Mutex<Option<wgpu::Texture>>,
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
        Self { gate: pipe("glitch_gate"), chroma: pipe("glitch_chroma"), compose: pipe("glitch_compose"), layout, vcr: VcrGpu::new(device), vcr_output: Default::default() }
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
        let signal = CompositeSignal::new(s);
        let width = input.width();
        let us_per_pixel = T::ACTIVE_LENGTH / width as f64;
        let ghost_delay = s.get("ghost_delay");
        let ghost_angle = -2.0 * PI * T::SUBCARRIER_MHZ * ghost_delay;
        let snap = |v: f32, target: f32| if (v - target).abs() < 1e-6 { target } else { v };
        // The VCR plays the picture from tape first; the TV receives that.
        let vcr_tex = plan.vcr.as_ref().map(|vp| {
            let mut slot = self.vcr_output.lock().expect("vcr texture");
            if slot.as_ref().map(|t| (t.width(), t.height())) != Some((input.width(), input.height())) {
                *slot = Some(device.create_texture(&wgpu::TextureDescriptor {
                    label: Some("vcr output"),
                    size: wgpu::Extent3d { width: input.width(), height: input.height(), depth_or_array_layers: 1 },
                    mip_level_count: 1,
                    sample_count: 1,
                    dimension: wgpu::TextureDimension::D2,
                    format: wgpu::TextureFormat::Rgba16Float,
                    usage: wgpu::TextureUsages::STORAGE_BINDING | wgpu::TextureUsages::TEXTURE_BINDING,
                    view_formats: &[],
                }));
            }
            let tex = slot.as_ref().expect("vcr texture").clone();
            self.vcr.encode(device, queue, enc, input, &tex, vp, s, &raster, plan.field_index);
            tex
        });
        let picture = vcr_tex.as_ref().unwrap_or(input);
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
            // 1 when the picture arrives as a signal through the antenna
            // socket; then the fields since the start, for the subcarrier's
            // phase (the plan's field index is the TV line its scan started
            // on).
            signal.on as u32,
            (plan.field_index as f64 / (raster.total_lines() as f64).max(1.0)).round() as u32,
            ((0.38 / us_per_pixel).round() as u32).max(1),
            ((0.83 / us_per_pixel).round() as u32).max(1),
            plan.color_on as u32,
        ];
        let f32s: [f32; 24] = [
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
            // The composite signal: a sample's length (µs), a sample's noise
            // for each IRE in the video band, the color's strength going in,
            // what the tuner leaves at the subcarrier, how many samples
            // before the pixel the filter table is in use.
            composite::SAMPLE_US as f32,
            composite::noise_per_sample() as f32,
            signal.color_in_signal() as f32,
            signal.burst_gain() as f32,
            signal.taps_before() as f32,
            0.0,
            0.0,
            0.0,
        ];
        let mut uniform: Vec<u8> = Vec::with_capacity(160);
        u32s.iter().for_each(|v| uniform.extend_from_slice(&v.to_le_bytes()));
        f32s.iter().for_each(|v| uniform.extend_from_slice(&v.to_le_bytes()));
        let buffer = |data: &[u8], usage: wgpu::BufferUsages| {
            let b = device.create_buffer(&wgpu::BufferDescriptor { label: None, size: data.len().max(16) as u64, usage: usage | wgpu::BufferUsages::COPY_DST, mapped_at_creation: false });
            queue.write_buffer(&b, 0, data);
            b
        };
        let ubuf = buffer(&uniform, wgpu::BufferUsages::UNIFORM);
        let rbuf = buffer(bytemuck::cast_slice(rows), wgpu::BufferUsages::STORAGE);
        let tbuf = buffer(bytemuck::cast_slice(&signal.signal_taps()), wgpu::BufferUsages::STORAGE);
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
                wgpu::BindGroupEntry { binding: 4, resource: tbuf.as_entire_binding() },
                wgpu::BindGroupEntry { binding: 5, resource: wgpu::BindingResource::TextureView(&picture.create_view(&Default::default())) },
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

#[cfg(test)]
mod tests {
    use super::*;

    fn settings(values: &[(&str, f64)]) -> GlitchSettings {
        let mut s = GlitchSettings::default();
        for (k, v) in values {
            s.values.insert(k.to_string(), *v);
        }
        s
    }

    fn frame(settings: GlitchSettings, time: f64, history: Option<GlitchHistory>) -> GlitchFrame {
        GlitchFrame { settings, time, history }
    }

    /// Plan on the background renderer until its re-run has landed.
    fn settled(r: &mut Renderer, raster: Raster, f: &GlitchFrame) -> FieldPlan {
        let _ = r.plan(raster, f);
        let deadline = std::time::Instant::now() + std::time::Duration::from_secs(60);
        while r.rerun_pending() && std::time::Instant::now() < deadline {
            if r.take_landed() {
                break;
            }
            std::thread::sleep(std::time::Duration::from_millis(5));
        }
        assert!(!r.rerun_pending(), "background re-run never landed");
        r.plan(raster, f)
    }

    fn same(a: &FieldPlan, b: &FieldPlan) {
        assert_eq!(a.rows, b.rows);
        assert_eq!(format!("{:?}", a.vcr), format!("{:?}", b.vcr));
        assert_eq!(a.chroma_phase, b.chroma_phase);
    }

    /// A timing knob turned on a paused frame far into a clip: the preview
    /// shows something at once, and once the background re-run lands the
    /// frame is exactly what a full re-run gives (the Mac's 0.26.1 fix).
    #[test]
    fn a_background_rerun_after_a_retune_matches_a_full_rerun() {
        let raster = Raster::new(320, 240);
        let mut values = vec![("vcr", 1.0), ("tracking_offset", 0.3), ("back_tension", 0.2), ("tape_sticky", 0.5), ("dirt_buildup", 0.6), ("tape_mold", 0.4)];
        let mut preview = Renderer::default();
        preview.background = true;
        settled(&mut preview, raster, &frame(settings(&values), 6.0, None));
        values[2] = ("back_tension", 0.6);
        let f = frame(settings(&values), 6.0, None);
        let meanwhile = preview.plan(raster, &f);
        assert!(!meanwhile.rows.is_empty());
        assert!(preview.rerun_pending(), "a 6 s re-run goes to the background");
        let landed = settled(&mut preview, raster, &f);
        same(&landed, &Renderer::default().plan(raster, &f));
        // Its checkpoints are good for seeking back, too.
        let back = frame(settings(&values), 3.5, None);
        same(&preview.plan(raster, &back), &Renderer::default().plan(raster, &back));
    }

    fn worn() -> GlitchSettings {
        settings(&[("vcr", 1.0), ("tracking_offset", 0.3), ("back_tension", 0.2), ("tape_sticky", 0.5), ("dirt_buildup", 0.6), ("tape_mold", 0.4), ("signal_strength", 0.4)])
    }

    /// A looping clip comes back to its first frame every few seconds. The
    /// preview has the warmed-up set of time zero on hand, so the frame is
    /// exact at once: nothing to wait for. (Each loop used to re-run the
    /// warm-up in the background and hold the last frame's picture until it
    /// landed: the tape looked frozen for the clip's first second or two.)
    #[test]
    fn a_loop_back_to_the_start_is_exact_at_once() {
        let raster = Raster::new(320, 240);
        let step = 1.0 / 24.0;
        let mut preview = Renderer::default();
        preview.background = true;
        settled(&mut preview, raster, &frame(worn(), 0.0, None));
        for k in 0..=60 {
            preview.plan(raster, &frame(worn(), k as f64 * step, None)); // plays on
        }
        let mut export = Renderer::default();
        for k in 0..=3 {
            // and loops
            let f = frame(worn(), k as f64 * step, None);
            let looped = preview.plan(raster, &f);
            assert!(!preview.rerun_pending(), "frame {k} after the loop went to the background");
            same(&looped, &export.plan(raster, &f));
        }
    }

    /// The same with keyframed knobs.
    #[test]
    fn a_loop_back_to_the_start_is_exact_at_once_with_keyframes() {
        let raster = Raster::new(320, 240);
        let step = 1.0 / 24.0;
        let history = GlitchHistory {
            frame_duration: step,
            id: 11,
            settings_at: Arc::new(|t| settings(&[("vcr", 1.0), ("tracking_offset", (t / 5.0).min(0.6)), ("tape_sticky", (t / 3.0).min(1.0)), ("signal_strength", 0.4)])),
        };
        let at = |t: f64| frame((history.settings_at)(t), t, Some(history.clone()));
        let mut preview = Renderer::default();
        preview.background = true;
        settled(&mut preview, raster, &at(0.0));
        for k in 0..=60 {
            preview.plan(raster, &at(k as f64 * step));
        }
        let mut export = Renderer::default();
        for k in 0..=3 {
            let f = at(k as f64 * step);
            let looped = preview.plan(raster, &f);
            assert!(!preview.rerun_pending(), "frame {k} after the loop went to the background");
            same(&looped, &export.plan(raster, &f));
        }
    }

    /// A finished background re-run is taken up by the next frame planned.
    #[test]
    fn a_finished_rerun_is_taken_up_by_the_next_frame() {
        let raster = Raster::new(320, 240);
        let f = frame(worn(), 6.0, None);
        let exact = Renderer::default().plan(raster, &f);
        let mut preview = Renderer::default();
        preview.background = true;
        let mut shown = preview.plan(raster, &f); // starts the re-run
        let deadline = std::time::Instant::now() + std::time::Duration::from_secs(30);
        while shown.rows != exact.rows && std::time::Instant::now() < deadline {
            std::thread::sleep(std::time::Duration::from_millis(20));
            shown = preview.plan(raster, &f);
        }
        same(&shown, &exact);
    }

    /// While a re-run is in flight a playing picture keeps moving: the state
    /// on hand runs on by as much as the playhead did.
    #[test]
    fn a_playing_picture_keeps_moving_while_a_rerun_is_in_flight() {
        let raster = Raster::new(320, 240);
        let step = 1.0 / 24.0;
        let mut preview = Renderer::default();
        preview.background = true;
        let mut last = preview.plan(raster, &frame(worn(), 40.0, None)); // a long re-run starts
        for k in 1..=4 {
            let next = preview.plan(raster, &frame(worn(), 40.0 + k as f64 * step, None));
            assert_ne!(next.rows, last.rows, "frame {k} stood still");
            last = next;
        }
        // Paused, it holds still.
        let f = frame(worn(), 40.0 + 4.0 * step, None);
        let held = preview.plan(raster, &f);
        if held.rows != last.rows {
            // (unless the re-run landed in between, which is exact)
            same(&held, &Renderer::default().plan(raster, &f));
        }
    }

    #[test]
    fn a_background_rerun_after_a_jump_matches_a_full_rerun_with_keyframes() {
        let raster = Raster::new(320, 240);
        let history = GlitchHistory {
            frame_duration: 1.0 / 24.0,
            id: 9,
            settings_at: Arc::new(|t| {
                settings(&[
                    ("vcr", 1.0),
                    ("tracking_offset", (t / 5.0).min(0.6)),
                    ("back_tension", if t > 2.3 { 0.6 } else { 0.0 }),
                    ("tape_sticky", (t / 3.0).min(1.0)),
                    ("vertical_hold", (t / 6.0).min(0.9)),
                ])
            }),
        };
        let t = 130.0 / 24.0;
        let f = frame((history.settings_at)(t), t, Some(history.clone()));
        let mut preview = Renderer::default();
        preview.background = true;
        let landed = settled(&mut preview, raster, &f);
        same(&landed, &Renderer::default().plan(raster, &f));
    }
}
