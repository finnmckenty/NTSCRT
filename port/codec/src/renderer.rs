//! The stage around the codec (`DigitalVideoRenderer.swift`): timing, the
//! camera (sensor sampling, electronics), the stream's state between frames,
//! and the picture back out.
//!
//! Pixels are RGBA8 here (the Mac passes BGRA8). Everywhere the math looks
//! at a channel by position it reads the same color the Mac does, so the two
//! agree value for value.

use std::borrow::Cow;
use std::collections::{HashMap, VecDeque};
use std::hash::{Hash, Hasher};
use std::sync::Arc;

use rayon::prelude::*;

use crate::codec::{clampf, CodecFrameKind, CodecGeometry, CodecPicture, CodecState, DigitalCodec, FrameSettings, SplitMix, Steps};
use crate::params::{hash_f64, swift_max, swift_min, DigitalCodecKind, DigitalSettings};
use crate::resample::scale_lanczos;
use crate::tables::SRGB_TO_LINEAR_BITS;
use crate::video1::Video1Codec;

/// When the camera captures and where keyframes fall, for one render.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct DigitalTiming {
    /// The clip's (or timeline's) frame rate.
    pub source_fps: f64,
    /// The camera's, never above the source's (it can't make frames up).
    pub capture_fps: f64,
    /// Captures from one keyframe to the next; 1 codes every frame alone.
    pub keyframe_every: i64,
}

impl Eq for DigitalTiming {}

impl Hash for DigitalTiming {
    fn hash<H: Hasher>(&self, state: &mut H) {
        hash_f64(self.source_fps, state);
        hash_f64(self.capture_fps, state);
        self.keyframe_every.hash(state);
    }
}

impl DigitalTiming {
    pub fn new(source_fps: f64, settings: &DigitalSettings) -> Self {
        let source_fps = swift_max(1.0, source_fps);
        // Whole frames a second (looks saved before the slider snapped may
        // hold fractions).
        let capture_fps = swift_min(source_fps, swift_max(1.0, settings.get("frame_rate").round()));
        let seconds = settings.get("keyframe_interval");
        let keyframe_every = if seconds <= 0.0 { 1 } else { swift_max(2, (seconds * capture_fps).round() as i64) };
        DigitalTiming { source_fps, capture_fps, keyframe_every }
    }

    fn ratio(&self) -> f64 {
        self.capture_fps / self.source_fps
    }

    /// The capture a source frame shows (the latest one taken by then).
    pub fn capture_of_frame(&self, n: i64) -> i64 {
        let ratio = self.ratio();
        if ratio >= 1.0 { n } else { (n as f64 * ratio + 1e-9).floor() as i64 }
    }

    /// The source frame a capture is taken from: the first that shows it.
    pub fn frame_of_capture(&self, c: i64) -> i64 {
        let ratio = self.ratio();
        if ratio >= 1.0 { c } else { (c as f64 / ratio - 1e-9).ceil() as i64 }
    }

    pub fn intra_only(&self) -> bool {
        self.keyframe_every == 1
    }

    pub fn kind_of_capture(&self, c: i64, datamosh: f64) -> CodecFrameKind {
        if self.intra_only() {
            return CodecFrameKind::IntraOnly;
        }
        if c % self.keyframe_every != 0 {
            return CodecFrameKind::Predicted;
        }
        if DigitalCodec::drops_key(c / self.keyframe_every, datamosh) {
            CodecFrameKind::DroppedKey
        } else {
            CodecFrameKind::Key
        }
    }
}

/// How the stage's settings vary over the timeline (keyframes), so a re-run
/// from an earlier keyframe repeats exactly what a straight run would do.
#[derive(Clone)]
pub struct DigitalHistory {
    /// Changes whenever the history would, so checkpoints taken under one
    /// history are never reused for another.
    pub id: i64,
    /// The settings at a source frame.
    pub settings_at: Arc<dyn Fn(i64) -> DigitalSettings + Send + Sync>,
}

impl DigitalHistory {
    pub fn new(id: i64, settings_at: impl Fn(i64) -> DigitalSettings + Send + Sync + 'static) -> Self {
        DigitalHistory { id, settings_at: Arc::new(settings_at) }
    }
}

impl std::fmt::Debug for DigitalHistory {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("DigitalHistory").field("id", &self.id).finish_non_exhaustive()
    }
}

/// Supplies an earlier source frame's pixels to `body`, for re-running the
/// codec from a keyframe: `visit(frame, body)` calls
/// `body(pixels, width, height, row_bytes)` with that frame as RGBA8, top row
/// first, and returns whether it could. Frames are asked for in increasing
/// order.
pub type FrameVisitor<'a> = dyn FnMut(i64, &mut dyn FnMut(&[u8], usize, usize, usize)) -> bool + 'a;

#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
struct StreamKey {
    geometry: CodecGeometry,
    timing: DigitalTiming,
    history: Option<i64>,
}

#[derive(Clone, Debug, PartialEq, Eq, Hash)]
struct CheckpointKey {
    stream: StreamKey,
    settings: Option<DigitalSettings>,
    capture: i64,
}

/// The settings each capture runs under: the frame's own from the history,
/// holding the render's structure.
struct SettingsFor<'a> {
    settings: &'a DigitalSettings,
    history: Option<&'a DigitalHistory>,
    timing: DigitalTiming,
}

impl SettingsFor<'_> {
    fn at(&self, c: i64) -> DigitalSettings {
        let Some(history) = self.history else { return self.settings.clone() };
        let mut s = (history.settings_at)(self.timing.frame_of_capture(c)).holding_structure(self.settings);
        s.set("chroma", self.settings.get("chroma"));
        s
    }
}

/// The Digital video stage for one consumer (the preview, playback, or one
/// export): a camera plus the codec, holding the stream's state between
/// frames.
///
/// Moving forward a frame at a time — playback, Animate, an export —
/// continues the stream. A jump, or new settings while time stands still,
/// re-runs it from the last keyframe the decoder actually received, so a
/// given frame always looks the same. Keyframes a datamosh throws away leave
/// the decoder with history reaching further back; the state at each one is
/// checkpointed so later jumps don't re-run from the start.
///
/// One renderer per consumer; it's `Send`, not shared.
pub struct DigitalVideoRenderer {
    stream: Option<StreamKey>,
    state: Option<CodecState>,
    last_capture: Option<i64>,
    last_settings: Option<DigitalSettings>,
    /// The settings every step since the last fresh start ran under (`None`
    /// once they changed mid-run, which makes the run unfit to checkpoint).
    run_settings: Option<Option<DigitalSettings>>,
    /// The decoded picture of `last_capture`, as RGBA at the capture size.
    shown: Vec<u8>,
    shown_size: (usize, usize),

    checkpoints: HashMap<CheckpointKey, CodecState>,
    checkpoint_order: VecDeque<CheckpointKey>,
    checkpoint_bytes: usize,

    /// Captures re-run since the last call (for tests and the perf log).
    pub last_run_length: usize,
}

impl Default for DigitalVideoRenderer {
    fn default() -> Self {
        Self::new()
    }
}

/// sRGB code value (0–255) → linear light.
#[inline(always)]
pub(crate) fn srgb_to_linear(i: usize) -> f32 {
    f32::from_bits(SRGB_TO_LINEAR_BITS[i])
}

impl DigitalVideoRenderer {
    pub const CHECKPOINT_BUDGET: usize = 96 << 20;

    pub fn new() -> Self {
        DigitalVideoRenderer {
            stream: None,
            state: None,
            last_capture: None,
            last_settings: None,
            run_settings: None,
            shown: Vec::new(),
            shown_size: (0, 0),
            checkpoints: HashMap::new(),
            checkpoint_order: VecDeque::new(),
            checkpoint_bytes: 0,
            last_run_length: 0,
        }
    }

    /// The capture size for a picture of `width` × `height` at a capture
    /// width — the Downscale's own rule (height from the aspect, even).
    pub fn capture_size(width: usize, height: usize, capture_width: usize) -> (usize, usize) {
        let cw = swift_max(16, swift_min(capture_width, width));
        let aspect = swift_max(0.05, width as f64 / swift_max(1, height) as f64);
        (cw, swift_max(16, 2 * (cw as f64 / aspect / 2.0).round() as usize))
    }

    /// Replace frame `n`'s pixels with what the camera and codec make of it.
    ///
    /// - `pixels`: frame `n` (RGBA8, `row_bytes` apart), rewritten in place at
    ///   the same size — the stage's picture scaled back up with hard pixels,
    ///   so a Downscale to `capture_size` afterwards gives it back exactly.
    ///   Alpha comes out 255.
    /// - `capture_size`: the camera's resolution (the Downscale size).
    /// - `source_fps`: the clip's frame rate, or the timeline's for a still.
    /// - `history`: per-frame settings from keyframes, else `None`.
    /// - `earlier`: earlier frames for a re-run; `None` means the picture
    ///   never changes (a still), so `pixels` stands in for every frame.
    #[allow(clippy::too_many_arguments)]
    pub fn process(
        &mut self,
        n: i64,
        pixels: &mut [u8],
        width: usize,
        height: usize,
        row_bytes: usize,
        capture_size: (usize, usize),
        source_fps: f64,
        settings: &DigitalSettings,
        history: Option<&DigitalHistory>,
        earlier: Option<&mut FrameVisitor<'_>>,
    ) {
        self.run_frame(n, pixels, width, height, row_bytes, capture_size, source_fps, settings, history, earlier);
        Self::upscale(&self.shown, capture_size, pixels, width, height, row_bytes);
    }

    /// `process` for a frame that won't be seen: the codec takes it (so the
    /// next frames come out right) but `pixels` is left as it was.
    #[allow(clippy::too_many_arguments)]
    pub fn process_unseen(
        &mut self,
        n: i64,
        pixels: &[u8],
        width: usize,
        height: usize,
        row_bytes: usize,
        capture_size: (usize, usize),
        source_fps: f64,
        settings: &DigitalSettings,
        history: Option<&DigitalHistory>,
        earlier: Option<&mut FrameVisitor<'_>>,
    ) {
        self.run_frame(n, pixels, width, height, row_bytes, capture_size, source_fps, settings, history, earlier);
    }

    #[allow(clippy::too_many_arguments)]
    fn run_frame(
        &mut self,
        n: i64,
        pixels: &[u8],
        width: usize,
        height: usize,
        row_bytes: usize,
        capture_size: (usize, usize),
        source_fps: f64,
        settings: &DigitalSettings,
        history: Option<&DigitalHistory>,
        mut earlier: Option<&mut FrameVisitor<'_>>,
    ) {
        let structure = settings;
        let timing = DigitalTiming::new(source_fps, structure);
        let geometry = CodecGeometry::new(capture_size.0, capture_size.1, structure.chroma());
        let key = StreamKey { geometry, timing, history: history.map(|h| h.id) };
        if Some(key) != self.stream {
            self.stream = Some(key);
            self.state = None;
            self.last_capture = None;
            self.last_settings = None;
        }
        let sf = SettingsFor { settings, history, timing };

        let c = timing.capture_of_frame(n);
        let now = sf.at(c);
        self.last_run_length = 0;

        // The current picture at the capture size, scaled once.
        let current = Self::scale(pixels, width, height, row_bytes, capture_size, structure);

        let last = self.last_capture;
        if last == Some(c) && self.state.is_some() && self.last_settings.as_ref() == Some(&now) {
            // Same frame, same settings: what's shown already.
        } else if let Some(last) = last.filter(|&l| self.state.is_some() && c > l && c - l <= swift_max(2, 2 * timing.keyframe_every)) {
            // Moving forward: carry on (new settings act from here on).
            let mut ok = true;
            for k in (last + 1)..=c {
                let src: Option<Cow<[u8]>> = if timing.frame_of_capture(k) == n {
                    Some(Cow::Borrowed(&current))
                } else {
                    Self::earlier_capture(k, &timing, earlier.as_deref_mut(), &current, capture_size, structure)
                };
                let Some(src) = src else {
                    ok = false;
                    break;
                };
                self.advance(k, &src, &geometry, &timing, &sf.at(k), key, history);
            }
            if !ok {
                self.rerun(c, n, &current, &geometry, &timing, key, history, earlier.as_deref_mut(), &sf);
            }
        } else {
            self.rerun(c, n, &current, &geometry, &timing, key, history, earlier.as_deref_mut(), &sf);
        }
        self.last_settings = Some(now);
    }

    // MARK: - running the stream

    /// Re-run from the last point the decoder's picture is known: a keyframe
    /// it received, or a checkpoint at one it lost.
    #[allow(clippy::too_many_arguments)]
    fn rerun(
        &mut self,
        c: i64,
        n: i64,
        current: &[u8],
        geometry: &CodecGeometry,
        timing: &DigitalTiming,
        key: StreamKey,
        history: Option<&DigitalHistory>,
        mut earlier: Option<&mut FrameVisitor<'_>>,
        sf: &SettingsFor<'_>,
    ) {
        let g = timing.keyframe_every;
        let checkpoint_settings: Option<DigitalSettings> = if history.is_none() { Some(sf.at(c)) } else { None };
        let start: i64;
        let mut restored: Option<CodecState> = None;
        if timing.intra_only() {
            // Each frame stands alone; only the one before (for patching lost
            // blocks) matters.
            start = swift_max(0, c - 1);
        } else {
            let mut b = (c / g) * g;
            while b > 0 {
                let kind = timing.kind_of_capture(b, sf.at(b).effective("datamosh"));
                if kind == CodecFrameKind::Key {
                    break;
                }
                let ck = CheckpointKey { stream: key, settings: checkpoint_settings.clone(), capture: b };
                if let Some(saved) = self.checkpoints.get(&ck) {
                    restored = Some(saved.clone());
                    break;
                }
                b -= g;
            }
            start = b;
        }
        let was_restored = restored.is_some();
        self.state = Some(restored.unwrap_or_else(|| CodecState::new(*geometry)));
        self.run_settings = Some(checkpoint_settings);
        let first = if was_restored { start + 1 } else { start };
        self.last_capture = if was_restored { Some(start) } else { None };
        if first > c {
            // The checkpoint is the frame itself.
            let s = sf.at(c);
            let step = Steps::new(s.get("quality"), 1.0).inter;
            let decoded = self.state.as_ref().unwrap().decoder.clone().unwrap();
            self.shown = Self::render(&decoded, geometry, &s, step);
            self.shown_size = (geometry.width, geometry.height);
            self.last_capture = Some(c);
            return;
        }
        for k in first..=c {
            // The camera took capture k at its first frame; `current` is
            // frame n, which may be a later repeat of it.
            let src: Cow<[u8]> = if timing.frame_of_capture(k) == n {
                Cow::Borrowed(current)
            } else {
                Self::earlier_capture(k, timing, earlier.as_deref_mut(), current, (geometry.width, geometry.height), &sf.at(c))
                    .unwrap_or(Cow::Borrowed(current))
            };
            self.advance(k, &src, geometry, timing, &sf.at(k), key, history);
        }
    }

    /// The capture-size picture for capture `k`, from an earlier frame — or
    /// the current one when the picture never changes.
    fn earlier_capture<'c>(
        k: i64,
        timing: &DigitalTiming,
        earlier: Option<&mut FrameVisitor<'_>>,
        current: &'c [u8],
        size: (usize, usize),
        optics: &DigitalSettings,
    ) -> Option<Cow<'c, [u8]>> {
        let Some(earlier) = earlier else { return Some(Cow::Borrowed(current)) };
        let mut out: Option<Vec<u8>> = None;
        let ok = earlier(timing.frame_of_capture(k), &mut |base, w, h, rb| {
            out = Some(Self::scale(base, w, h, rb, size, optics));
        });
        if ok { out.map(Cow::Owned) } else { None }
    }

    /// Code capture `k` and keep what the decoder shows.
    #[allow(clippy::too_many_arguments)]
    fn advance(
        &mut self,
        k: i64,
        source: &[u8],
        geometry: &CodecGeometry,
        timing: &DigitalTiming,
        settings: &DigitalSettings,
        key: StreamKey,
        history: Option<&DigitalHistory>,
    ) {
        let state = self.state.get_or_insert_with(|| CodecState::new(*geometry));
        let picture = Self::capture(source, geometry, settings, k);
        let mut kind = timing.kind_of_capture(k, settings.effective("datamosh"));
        if kind != CodecFrameKind::IntraOnly && state.encoder.is_none() {
            kind = CodecFrameKind::Key;
        }
        let frame = FrameSettings {
            quality: settings.get("quality"),
            fixed_bitrate: settings.get("fixed_bitrate"),
            data_loss: settings.get("data_loss"),
        };
        let (shown, step) = match settings.codec() {
            DigitalCodecKind::Dct => DigitalCodec::step(state, &picture, kind, k, &frame),
            DigitalCodecKind::BlockColors => (Video1Codec::step(state, &picture, kind, k, &frame), 0.0),
        };
        self.last_run_length += 1;
        self.last_capture = Some(k);
        self.shown = Self::render(&shown, geometry, settings, step);
        self.shown_size = (geometry.width, geometry.height);

        // A run under one set of settings can be checkpointed at keyframes
        // the decoder lost (the only places its history reaches past).
        let checkpoint_settings: Option<DigitalSettings> = if history.is_none() { Some(settings.clone()) } else { None };
        if let Some(run) = &self.run_settings {
            if *run != checkpoint_settings {
                self.run_settings = None;
            }
        }
        if kind == CodecFrameKind::DroppedKey {
            if let Some(run) = self.run_settings.clone() {
                let snapshot = self.state.as_ref().unwrap().clone();
                self.store(CheckpointKey { stream: key, settings: run, capture: k }, snapshot);
            }
        }
    }

    fn store(&mut self, key: CheckpointKey, s: CodecState) {
        if self.checkpoints.contains_key(&key) {
            return;
        }
        let bytes = s.encoder.as_ref().map_or(0, |e| e.byte_count()) * 2;
        self.checkpoints.insert(key.clone(), s);
        self.checkpoint_order.push_back(key);
        self.checkpoint_bytes += bytes;
        while self.checkpoint_bytes > Self::CHECKPOINT_BUDGET {
            let Some(oldest) = self.checkpoint_order.pop_front() else { break };
            if let Some(old) = self.checkpoints.remove(&oldest) {
                self.checkpoint_bytes -= old.encoder.as_ref().map_or(0, |e| e.byte_count()) * 2;
            }
        }
    }

    // MARK: - pixels in

    /// RGBA8 at any size → tightly packed RGBA8 at `size`: what the sensor
    /// reads through the lens. A proper area sampling (the Mac's vImage
    /// high-quality resampler; here `resample::scale_lanczos`, its
    /// equivalent), blended toward point samples as Aliasing rises to 50%, so
    /// detail the sensor can't resolve beats into moiré. Red, green and blue
    /// are read a third of a capture pixel apart: where a beat drifts slowly
    /// the three see it at phases 120° apart, so its color turns full circle
    /// — rainbows. (Half a pixel, as a 3-CCD camera's green offset is, puts
    /// them in opposite phase there: only a faint magenta-green survives DV's
    /// quarter-width color.) Above 50% the source's finest detail is boosted
    /// at each sample, for strong moiré even from sources not much sharper
    /// than the camera. Then, for One field, every other line repeated.
    pub fn scale(base: &[u8], width: usize, height: usize, row_bytes: usize, size: (usize, usize), optics: &DigitalSettings) -> Vec<u8> {
        let (cw, ch) = size;
        let mut out = vec![0u8; cw * ch * 4];
        if width == cw && height == ch {
            for y in 0..height {
                out[y * cw * 4..(y + 1) * cw * 4].copy_from_slice(&base[y * row_bytes..y * row_bytes + width * 4]);
            }
        } else {
            scale_lanczos(base, width, height, row_bytes, &mut out, cw, ch);
        }
        let aliasing = optics.get("aliasing") as f32;
        if aliasing > 0.0 {
            let mix = swift_min(1.0, aliasing * 2.0);
            let boost = swift_max(0.0, aliasing * 2.0 - 1.0) * 1.5;
            let kx = width as f64 / cw as f64;
            let ky = height as f64 / ch as f64;
            out.par_chunks_mut(cw * 4).enumerate().for_each(|(y, o)| {
                let sy = swift_min(height - 1, ((y as f64 + 0.5) * ky) as usize);
                let rows = [swift_max(0, sy as isize - 1) as usize, sy, swift_min(height - 1, sy + 1)].map(|r| &base[r * row_bytes..]);
                // One channel at source pixel `sx`, its fine detail boosted.
                let read = |sx: usize, c: usize| -> f32 {
                    let v = rows[1][sx * 4 + c] as f32;
                    if !(boost > 0.0) {
                        return v;
                    }
                    let mut sum = 0f32;
                    for r in &rows {
                        for dx in -1isize..=1 {
                            let xx = swift_min(width as isize - 1, swift_max(0, sx as isize + dx)) as usize;
                            sum += r[xx * 4 + c] as f32;
                        }
                    }
                    clampf(v + boost * (v - sum / 9.0), 0.0, 255.0)
                };
                for x in 0..cw {
                    let center = (x as f64 + 0.5) * kx;
                    let xg = swift_min(width - 1, center as usize);
                    let xr = swift_min(width as i64 - 1, swift_max(0, (center - kx / 3.0) as i64)) as usize;
                    let xb = swift_min(width - 1, (center + kx / 3.0) as usize);
                    let i = x * 4;
                    let pr = read(xr, 0);
                    let pg = read(xg, 1);
                    let pb = read(xb, 2);
                    for (c, p) in [(0, pr), (1, pg), (2, pb)] {
                        let o0 = o[i + c] as f32;
                        o[i + c] = (o0 + (p - o0) * mix).round() as u8;
                    }
                }
            });
        }
        if optics.get("fields") >= 0.5 {
            // One field: the even lines, each shown twice.
            let row = cw * 4;
            let mut y = 1;
            while y < ch {
                out.copy_within((y - 1) * row..y * row, y * row);
                y += 2;
            }
        }
        out
    }

    /// The camera's electronics, on what the sensor read (`rgba`, at the
    /// capture size). In light (linear): white balance as gains, then the CCD
    /// response's auto exposure and lens flare. Back in video levels: sensor
    /// noise, then each channel through the knee and clipped at white on its
    /// own. Then, in Y′CbCr: noise reduction, the detail circuit's
    /// sharpening, the setup lift and saturation, and finally the color
    /// subsampled.
    pub fn capture(rgba: &[u8], g: &CodecGeometry, settings: &DigitalSettings, index: i64) -> CodecPicture {
        let w = g.width;
        let h = g.height;
        let mut noise = settings.get("sensor_noise") as f32;
        let low_light = settings.get("low_light_noise") as f32;
        let nr = settings.get("noise_reduction") as f32;
        let warm = settings.get("white_balance") as f32;
        let magenta = settings.get("tint") as f32;
        let ccd = settings.get("ccd_response") as f32;
        let curve = CcdResponse { strength: ccd };
        let mut gain_r = 1.0 + 0.25 * warm;
        let mut gain_b = 1.0 - 0.25 * warm;
        let mut gain_g = 1.0 - 0.15 * magenta;
        let mut flare = 0f32;
        if low_light > 0.0 && noise > 0.0 {
            noise *= 1.0 + low_light * (Self::sensor_gain(Self::median_luma(rgba, w, h)) - 1.0);
        }
        if ccd > 0.0 {
            let exposure = curve.exposure(Self::metered_mean(rgba, w, h, (gain_r, gain_g, gain_b)));
            gain_r *= exposure;
            gain_g *= exposure;
            gain_b *= exposure;
            flare = curve.flare(Self::metered_mean(rgba, w, h, (gain_r, gain_g, gain_b)));
        }
        // Gains act on light, so they need linear values (decoded sRGB).
        let linear = gain_r != 1.0 || gain_g != 1.0 || gain_b != 1.0 || flare > 0.0;
        let mut yf = vec![0f32; w * h];
        let mut cbf = vec![0f32; w * h];
        let mut crf = vec![0f32; w * h];
        yf.par_chunks_mut(w)
            .zip(cbf.par_chunks_mut(w))
            .zip(crf.par_chunks_mut(w))
            .enumerate()
            .for_each(|(y, ((yr, cbr), crr))| {
                // The row's seed hashed first: SplitMix steps its state by
                // the same constant the row number is multiplied by, so
                // unhashed, each row would replay the row above a few pixels
                // along (streaks instead of grain).
                let mut seeder = SplitMix::new(
                    (index as u64).wrapping_mul(0x2545_F491_4F6C_DD1D) ^ (y as u64).wrapping_mul(0x9E37_79B9_7F4A_7C15),
                );
                let mut rng = SplitMix::new(seeder.next());
                let mut gauss = || -> f32 {
                    let a = rng.unit();
                    let b = rng.unit();
                    (a + b - 1.0) as f32 * 2.449
                };
                for x in 0..w {
                    let i = y * w + x;
                    let mut r = rgba[i * 4] as f32;
                    let mut gr = rgba[i * 4 + 1] as f32;
                    let mut b = rgba[i * 4 + 2] as f32;
                    if linear {
                        r = Self::linear_to_srgb(srgb_to_linear(r as usize) * gain_r + flare);
                        gr = Self::linear_to_srgb(srgb_to_linear(gr as usize) * gain_g + flare);
                        b = Self::linear_to_srgb(srgb_to_linear(b as usize) * gain_b + flare);
                    }
                    if noise > 0.0 {
                        // Gain noise: worst in the shadows, and under the
                        // clip (a blown sky is clean).
                        let shade = 1.3 - 0.6 * swift_min(255.0, 0.299 * r + 0.587 * gr + 0.114 * b) / 255.0;
                        let n = gauss() * 7.0 * noise * shade;
                        let nb = gauss() * 11.0 * noise * shade;
                        let nc = gauss() * 11.0 * noise * shade;
                        // Luma noise plus color noise along Cb and Cr.
                        r += n + 1.402 * nc;
                        gr += n - 0.344136 * nb - 0.714136 * nc;
                        b += n + 1.772 * nb;
                    }
                    if ccd > 0.0 {
                        r = curve.knee(r);
                        gr = curve.knee(gr);
                        b = curve.knee(b);
                    }
                    if linear || noise > 0.0 {
                        r = clampf(r, 0.0, 255.0);
                        gr = clampf(gr, 0.0, 255.0);
                        b = clampf(b, 0.0, 255.0);
                    }
                    yr[x] = 0.299 * r + 0.587 * gr + 0.114 * b;
                    cbr[x] = 128.0 - 0.168736 * r - 0.331264 * gr + 0.5 * b;
                    crr[x] = 128.0 + 0.5 * r - 0.418688 * gr - 0.081312 * b;
                }
            });
        if nr > 0.0 {
            yf = Self::sigma_filter(&yf, w, h, 4.0 + 26.0 * nr, swift_min(1.0, nr * 1.2));
            cbf = Self::box_blur(&cbf, w, h, 2, nr);
            crf = Self::box_blur(&crf, w, h, 2, nr);
        }
        let sharpening = settings.get("sharpening") as f32;
        if sharpening > 0.0 {
            // Detail: add back the difference from a local blur, so edges
            // overshoot both ways (halos), as wide as the blur. A fractional
            // width blends the two nearest whole radii.
            let width = swift_min(4.0, swift_max(1.0, settings.get("sharpening_width") as f32));
            let r = width as usize;
            let f = width - r as f32;
            let mut soft = Self::box_blur(&yf, w, h, r, 1.0);
            if f > 0.0 {
                let wider = Self::box_blur(&yf, w, h, r + 1, 1.0);
                for i in 0..soft.len() {
                    soft[i] += (wider[i] - soft[i]) * f;
                }
            }
            for i in 0..yf.len() {
                yf[i] = clampf(yf[i] + 2.2 * sharpening * (yf[i] - soft[i]), 0.0, 255.0);
            }
        }
        let black = curve.setup() * 255.0;
        let saturation = settings.get("saturation") as f32;
        if black > 0.0 || saturation != 1.0 {
            for i in 0..yf.len() {
                yf[i] = black + yf[i] * (1.0 - black / 255.0);
                cbf[i] = 128.0 + (cbf[i] - 128.0) * saturation;
                crf[i] = 128.0 + (crf[i] - 128.0) * saturation;
            }
        }
        let mut pic = CodecPicture::new(g);
        // Luma, padded by repeating the edge.
        let lw = pic.y.width;
        for y in 0..pic.y.height {
            let sy = swift_min(h - 1, y);
            for x in 0..lw {
                pic.y.data[y * lw + x] = yf[sy * w + swift_min(w - 1, x)];
            }
        }
        // Color, averaged over each sample's footprint.
        let (fx, fy) = (g.sx(), g.sy());
        let cw = pic.cb.width;
        let n = (fx * fy) as f32;
        for cy in 0..pic.cb.height {
            for cx in 0..cw {
                let mut sb = 0f32;
                let mut sr = 0f32;
                for dy in 0..fy {
                    let yy = swift_min(h - 1, cy * fy + dy);
                    for dx in 0..fx {
                        let i = yy * w + swift_min(w - 1, cx * fx + dx);
                        sb += cbf[i];
                        sr += crf[i];
                    }
                }
                pic.cb.data[cy * cw + cx] = sb / n;
                pic.cr.data[cy * cw + cx] = sr / n;
            }
        }
        pic
    }

    /// Linear light → sRGB code value (0–255), unclipped above white so the
    /// knee can still see how far over a channel is.
    #[inline(always)]
    pub fn linear_to_srgb(l: f32) -> f32 {
        let c = if l <= 0.0031308 { l * 12.92 } else { 1.055 * l.powf(1.0 / 2.4) - 0.055 };
        c * 255.0
    }

    /// The sensor gain a camera would have needed for a scene this dark,
    /// judged by its median brightness (`median_luma`, linear): none down to
    /// `gain_knee` (sRGB 100 — daylight footage sits above it), then rising
    /// as the median falls, up to 8× (+18 dB, a consumer camcorder's top).
    /// The median, not the exposure meter's center-weighted mean: sources are
    /// footage some camera already exposed, and a night shot's lit subject in
    /// the middle meters as bright as daylight, while half its frame stays
    /// black.
    pub fn gain_knee() -> f32 {
        srgb_to_linear(100)
    }

    pub fn sensor_gain(median_luma: f32) -> f32 {
        swift_min(8.0, swift_max(1.0, Self::gain_knee() / swift_max(median_luma, 1e-4)))
    }

    /// The median of the picture's brightness (Y′, every other pixel each
    /// way), as linear light.
    pub fn median_luma(rgba: &[u8], w: usize, h: usize) -> f32 {
        let mut counts = [0usize; 256];
        let mut n = 0usize;
        for y in (0..h).step_by(2) {
            for x in (0..w).step_by(2) {
                let i = (y * w + x) * 4;
                let l = (306 * rgba[i] as usize + 601 * rgba[i + 1] as usize + 117 * rgba[i + 2] as usize) >> 10;
                counts[swift_min(255, l)] += 1;
                n += 1;
            }
        }
        let mut seen = 0;
        for (v, &count) in counts.iter().enumerate() {
            seen += count;
            if seen * 2 >= n {
                return srgb_to_linear(v);
            }
        }
        1.0
    }

    /// Center-weighted mean of linear luminance, as camcorder auto exposure
    /// meters (the middle counts most, the edges a little).
    pub fn metered_mean(rgba: &[u8], w: usize, h: usize, gains: (f32, f32, f32)) -> f32 {
        let mut sum = 0f32;
        let mut weight = 0f32;
        for y in (0..h).step_by(2) {
            let dy = (y as f32 + 0.5) / h as f32 * 2.0 - 1.0;
            for x in (0..w).step_by(2) {
                let dx = (x as f32 + 0.5) / w as f32 * 2.0 - 1.0;
                let wt = swift_max(0.15, 1.0 - 0.6 * (dx * dx + dy * dy));
                let i = (y * w + x) * 4;
                let l = 0.2126 * srgb_to_linear(rgba[i] as usize) * gains.0
                    + 0.7152 * srgb_to_linear(rgba[i + 1] as usize) * gains.1
                    + 0.0722 * srgb_to_linear(rgba[i + 2] as usize) * gains.2;
                sum += l * wt;
                weight += wt;
            }
        }
        if weight > 0.0 { sum / weight } else { 0.18 }
    }

    /// Edge-preserving smoothing: each pixel moves toward the neighbors that
    /// are within `threshold` of it (a camera's noise reduction).
    pub fn sigma_filter(p: &[f32], w: usize, h: usize, threshold: f32, mix: f32) -> Vec<f32> {
        let mut out = p.to_vec();
        out.par_chunks_mut(w).enumerate().for_each(|(y, o)| {
            for x in 0..w {
                let c = p[y * w + x];
                let mut sum = 0f32;
                let mut n = 0f32;
                for dy in -1isize..=1 {
                    let yy = swift_min(h as isize - 1, swift_max(0, y as isize + dy)) as usize;
                    for dx in -1isize..=1 {
                        let xx = swift_min(w as isize - 1, swift_max(0, x as isize + dx)) as usize;
                        let v = p[yy * w + xx];
                        if (v - c).abs() < threshold {
                            sum += v;
                            n += 1.0;
                        }
                    }
                }
                o[x] = c + (sum / n - c) * mix;
            }
        });
        out
    }

    pub fn box_blur(p: &[f32], w: usize, h: usize, r: usize, mix: f32) -> Vec<f32> {
        let mut tmp = p.to_vec();
        let mut out = p.to_vec();
        let n = (2 * r + 1) as f32;
        let r = r as isize;
        tmp.par_chunks_mut(w).enumerate().for_each(|(y, t)| {
            for x in 0..w {
                let mut s = 0f32;
                for d in -r..=r {
                    s += p[y * w + swift_min(w as isize - 1, swift_max(0, x as isize + d)) as usize];
                }
                t[x] = s / n;
            }
        });
        out.par_chunks_mut(w).enumerate().for_each(|(y, o)| {
            for x in 0..w {
                let mut s = 0f32;
                for d in -r..=r {
                    s += tmp[swift_min(h as isize - 1, swift_max(0, y as isize + d)) as usize * w + x];
                }
                o[x] = p[y * w + x] + (s / n - p[y * w + x]) * mix;
            }
        });
        out
    }

    // MARK: - pixels out

    /// The decoder's picture as RGBA8 at the capture size: deblocked (on a
    /// copy — the reference stays as coded), color interpolated back up.
    pub fn render(decoded: &CodecPicture, g: &CodecGeometry, settings: &DigitalSettings, step: f32) -> Vec<u8> {
        let deblocking = settings.effective("deblocking");
        let deblocked;
        let picture = if deblocking > 0.0 {
            let mut p = decoded.clone();
            DigitalCodec::deblock(&mut p, deblocking, step);
            deblocked = p;
            &deblocked
        } else {
            decoded
        };
        let (w, h) = (g.width, g.height);
        let mut out = vec![255u8; w * h * 4];
        let fx = g.sx() as f32;
        let fy = g.sy() as f32;
        let (cb, cr, luma) = (&picture.cb, &picture.cr, &picture.y);
        out.par_chunks_mut(w * 4).enumerate().for_each(|(y, o)| {
            let cyf = (y as f32 + 0.5) / fy - 0.5;
            let cy0 = cyf.floor() as isize;
            let ty = cyf - cy0 as f32;
            for x in 0..w {
                let cxf = (x as f32 + 0.5) / fx - 0.5;
                let cx0 = cxf.floor() as isize;
                let tx = cxf - cx0 as f32;
                let bil = |p: &crate::codec::CodecPlane| -> f32 {
                    let a = p.clamped(cx0, cy0);
                    let b = p.clamped(cx0 + 1, cy0);
                    let c = p.clamped(cx0, cy0 + 1);
                    let d = p.clamped(cx0 + 1, cy0 + 1);
                    (a + (b - a) * tx) + ((c + (d - c) * tx) - (a + (b - a) * tx)) * ty
                };
                let yv = luma.data[y * luma.width + x];
                let u = bil(cb) - 128.0;
                let v = bil(cr) - 128.0;
                let r = yv + 1.402 * v;
                let gg = yv - 0.344136 * u - 0.714136 * v;
                let b = yv + 1.772 * u;
                let i = x * 4;
                o[i] = clampf(r.round(), 0.0, 255.0) as u8;
                o[i + 1] = clampf(gg.round(), 0.0, 255.0) as u8;
                o[i + 2] = clampf(b.round(), 0.0, 255.0) as u8;
                o[i + 3] = 255;
            }
        });
        out
    }

    /// Scale the capture-size picture back up with hard pixels. Each source
    /// pixel takes the capture pixel its center falls in, so a nearest
    /// Downscale (which samples pixel centers) returns the picture exactly.
    pub fn upscale(picture: &[u8], size: (usize, usize), base: &mut [u8], width: usize, height: usize, row_bytes: usize) {
        let (cw, ch) = size;
        if picture.len() != cw * ch * 4 {
            return;
        }
        let xs: Vec<usize> = (0..width)
            .map(|x| swift_min(cw - 1, ((x as f64 + 0.5) * cw as f64 / width as f64) as usize))
            .collect();
        base.par_chunks_mut(row_bytes).take(height).enumerate().for_each(|(y, drow)| {
            let sy = swift_min(ch - 1, ((y as f64 + 0.5) * ch as f64 / height as f64) as usize);
            let srow = &picture[sy * cw * 4..(sy + 1) * cw * 4];
            for x in 0..width {
                drow[x * 4..x * 4 + 4].copy_from_slice(&srow[xs[x] * 4..xs[x] * 4 + 4]);
            }
        });
    }
}

/// The tone of a 90s 3-CCD camcorder (the VX1000), fitted to its footage:
/// across six reference frames the darkest pixels sat at 20–45 (not 0),
/// medians at 130–210, and 10–32% of each frame piled up in the top bins,
/// with warm shots' red reaching white well before blue. `strength` blends
/// every part from nothing (0) to the full response (1).
#[derive(Clone, Copy, Debug)]
pub struct CcdResponse {
    pub strength: f32,
}

impl CcdResponse {
    /// Auto exposure: bring the metered mean to a bright target — these
    /// cameras exposed for faces and shadows and let skies go.
    pub const TARGET: f32 = 0.40;

    pub fn exposure(&self, metered_mean: f32) -> f32 {
        let full = swift_min(4.0, swift_max(0.5, Self::TARGET / swift_max(metered_mean, 1e-4)));
        full.powf(self.strength)
    }

    /// Veiling flare from a cheap lens (and the fisheye adapters these were
    /// shot through): a share of the whole frame's light scattered over
    /// everything, so bright scenes lift their shadows most.
    pub fn flare(&self, metered_mean: f32) -> f32 {
        0.03 * self.strength * metered_mean
    }

    /// The knee: above it each channel is compressed, then clips at white.
    pub const KNEE_POINT: f32 = 0.72 * 255.0;

    pub fn knee(&self, v: f32) -> f32 {
        if !(v > Self::KNEE_POINT) {
            return v;
        }
        let slope = 1.0 - 0.62 * self.strength;
        swift_min(255.0, Self::KNEE_POINT + (v - Self::KNEE_POINT) * slope)
    }

    /// NTSC DV's 7.5 IRE setup, mishandled in transfer: black shows as gray.
    pub fn setup(&self) -> f32 {
        0.065 * self.strength
    }
}
