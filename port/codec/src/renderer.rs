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

use crate::codec::{
    clampf, CodecFrameKind, CodecGeometry, CodecPicture, CodecState, Concealment, DigitalCodec, FrameSettings, LossPattern,
    SplitMix, Steps,
};
use crate::params::{hash_f64, swift_max, swift_min, DigitalCodecKind, DigitalSettings, FieldMode, SensorKind};
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

/// What the sensor readings kept between calls were made for.
#[derive(Clone, Copy, Debug, PartialEq)]
struct SensingKey {
    source: (usize, usize),
    width: usize,
    height: usize,
    aliasing: f64,
    sensor: f64,
}

/// What the sensor reads of the frames one call needs: the current one, and
/// earlier ones (decoded on demand, the last few kept), so an interlaced
/// camera's earlier field doesn't cost another decode of the frame before.
struct Sensing<'a, 'v> {
    cache: Vec<(i64, Vec<u8>)>,
    now: Vec<u8>,
    n: i64,
    earlier: Option<&'a mut FrameVisitor<'v>>,
    size: (usize, usize),
    optics: &'a DigitalSettings,
    mode: FieldMode,
}

impl Sensing<'_, '_> {
    /// What the sensor read of source frame `f`: `None` when it can't be had.
    fn sensed_frame(&mut self, f: i64) -> Option<Vec<u8>> {
        if f == self.n || self.earlier.is_none() {
            return Some(self.now.clone());
        }
        if let Some(hit) = self.cache.iter().find(|e| e.0 == f) {
            return Some(hit.1.clone());
        }
        let mut out: Option<Vec<u8>> = None;
        let (size, optics) = (self.size, self.optics);
        let ok = (self.earlier.as_mut().unwrap())(f, &mut |base, w, h, rb| {
            out = Some(DigitalVideoRenderer::sense(base, w, h, rb, size, optics));
        });
        if !ok {
            return None;
        }
        let out = out?;
        self.cache.push((f, out.clone()));
        if self.cache.len() > 3 {
            self.cache.remove(0);
        }
        Some(out)
    }

    /// The picture the camera hands the codec for source frame `f`.
    fn captured(&mut self, f: i64) -> Option<Vec<u8>> {
        // (The earlier field first: frames are asked for in order.)
        let before = if self.mode.is_interlaced() && f > 0 { self.sensed_frame(f - 1) } else { None };
        let now = self.sensed_frame(f)?;
        Some(DigitalVideoRenderer::fields(&now, before.as_deref(), self.size, self.mode))
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

    /// What the sensor read for the last couple of source frames (before the
    /// fields are put together). Valid for one sensing setup (`sensed_for`).
    sensed: Vec<(i64, Vec<u8>)>,
    sensed_for: Option<SensingKey>,

    checkpoints: HashMap<CheckpointKey, CodecState>,
    checkpoint_order: VecDeque<CheckpointKey>,
    checkpoint_bytes: usize,

    /// Captures re-run since the last call (for tests and the perf log).
    pub last_run_length: usize,

    /// A re-run longer than this many captures isn't done: the frame is
    /// coded on its own instead (a keyframe under the settings — no smear
    /// or datamosh from before it), and its pixels as they came in are kept
    /// in `deferred_pixels` for running it exactly elsewhere (the preview's
    /// background re-runs). `None` (the default) always re-runs.
    pub defer_rerun_above: Option<i64>,
    deferred_pixels: Option<Vec<u8>>,
    /// Checked once a capture during a re-run; set abandons it (the renderer
    /// is left mid-stream, so only a throwaway one should be cancelled).
    pub cancel: Option<std::sync::Arc<std::sync::atomic::AtomicBool>>,
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
            sensed: Vec::new(),
            sensed_for: None,
            checkpoints: HashMap::new(),
            checkpoint_order: VecDeque::new(),
            checkpoint_bytes: 0,
            last_run_length: 0,
            defer_rerun_above: None,
            deferred_pixels: None,
            cancel: None,
        }
    }

    /// After a `process` that deferred its re-run: the frame's pixels as
    /// they came in.
    pub fn take_deferred_pixels(&mut self) -> Option<Vec<u8>> {
        self.deferred_pixels.take()
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
        self.deferred_pixels = None;
        if self.run_frame(n, pixels, width, height, row_bytes, capture_size, source_fps, settings, history, earlier) {
            self.deferred_pixels = Some(pixels.to_vec());
        }
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
        let defer = self.defer_rerun_above.take();
        self.run_frame(n, pixels, width, height, row_bytes, capture_size, source_fps, settings, history, earlier);
        self.defer_rerun_above = defer;
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
    ) -> bool {
        let structure = settings;
        let timing = DigitalTiming::new(source_fps, structure);
        let geometry = CodecGeometry::with_block(capture_size.0, capture_size.1, structure.chroma(), structure.block_size());
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

        // What the sensor reads of the current frame, scaled once, and the
        // capture made of it. An interlaced camera's frame is two fields a
        // moment apart: this frame's even lines, the frame before's odd ones.
        let sensing_key = SensingKey {
            source: (width, height),
            width: capture_size.0,
            height: capture_size.1,
            aliasing: structure.get("aliasing"),
            sensor: structure.get("sensor"),
        };
        if Some(sensing_key) != self.sensed_for || earlier.is_none() {
            self.sensed.clear();
        }
        self.sensed_for = Some(sensing_key);
        let sensed_now = Self::sense(pixels, width, height, row_bytes, capture_size, structure);
        // The same frame number reading differently is another clip (or
        // another crop of it): nothing remembered belongs to it.
        if self.sensed.iter().any(|e| e.0 == n && e.1 != sensed_now) {
            self.sensed.clear();
        }
        let field_mode = structure.fields();
        let mut sensing = Sensing {
            cache: std::mem::take(&mut self.sensed),
            now: sensed_now,
            n,
            earlier: earlier.take(),
            size: capture_size,
            optics: structure,
            mode: field_mode,
        };
        let current = match sensing.captured(n) {
            Some(c) => c,
            None => Self::fields(&sensing.now, None, capture_size, field_mode),
        };

        let last = self.last_capture;
        let mut deferred = false;
        if last == Some(c) && self.state.is_some() && self.last_settings.as_ref() == Some(&now) {
            // Same frame, same settings: what's shown already.
        } else if let Some(last) = last.filter(|&l| self.state.is_some() && c > l && c - l <= swift_max(2, 2 * timing.keyframe_every)) {
            // Moving forward: carry on (new settings act from here on).
            let mut ok = true;
            for k in (last + 1)..=c {
                let src: Option<Cow<[u8]>> = if timing.frame_of_capture(k) == n {
                    Some(Cow::Borrowed(&current))
                } else {
                    sensing.captured(timing.frame_of_capture(k)).map(Cow::Owned)
                };
                let Some(src) = src else {
                    ok = false;
                    break;
                };
                self.advance(k, &src, &geometry, &timing, &sf.at(k), key, history);
            }
            if !ok {
                deferred = self.rerun(c, n, &current, &geometry, &timing, key, history, &mut sensing, &sf);
            }
        } else {
            deferred = self.rerun(c, n, &current, &geometry, &timing, key, history, &mut sensing, &sf);
        }
        self.last_settings = Some(now);
        // Keep this frame (and the one before) for the next call.
        let Sensing { mut cache, now: sensed_now, .. } = sensing;
        cache.retain(|e| e.0 != n);
        cache.push((n, sensed_now));
        if cache.len() > 3 {
            cache.remove(0);
        }
        self.sensed = cache;
        deferred
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
        sensing: &mut Sensing<'_, '_>,
        sf: &SettingsFor<'_>,
    ) -> bool {
        let g = timing.keyframe_every;
        let checkpoint_settings: Option<DigitalSettings> = if history.is_none() { Some(sf.at(c)) } else { None };
        let start: i64;
        let mut restored: Option<CodecState> = None;
        if timing.intra_only() {
            // Each frame stands alone; only the one before (for patching lost
            // blocks) matters — except on tape, where a patch holds what the
            // decoder last showed: back to the last clean read (and the frame
            // before that, which a stream's patch at it would use).
            let now = sf.at(c);
            let held = now.get("data_loss") > 0.0 && now.get("loss_pattern").round() as i64 != 0;
            let clean = (c / DigitalCodec::TAPE_REFRESH) * DigitalCodec::TAPE_REFRESH;
            start = swift_max(0, (if held { swift_min(c, clean) } else { c }) - 1);
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
        if self.defer_rerun_above.is_some_and(|limit| c - start > limit) {
            // See `defer_rerun_above`: this frame alone, unfit to checkpoint.
            self.state = Some(CodecState::new(*geometry));
            self.run_settings = None;
            self.advance(c, current, geometry, timing, &sf.at(c), key, history);
            return true;
        }
        let was_restored = restored.is_some();
        self.state = Some(restored.unwrap_or_else(|| CodecState::new(*geometry)));
        self.run_settings = Some(checkpoint_settings);
        let first = if was_restored { start + 1 } else { start };
        self.last_capture = if was_restored { Some(start) } else { None };
        if first > c {
            // The checkpoint is the frame itself.
            let s = sf.at(c);
            let step = Steps::with_block(s.get("quality"), 1.0, geometry.block).inter;
            let decoded = self.state.as_ref().unwrap().decoder.clone().unwrap();
            self.shown = Self::present(&decoded, geometry, &s, step);
            self.shown_size = (geometry.width, geometry.height);
            self.last_capture = Some(c);
            return false;
        }
        for k in first..=c {
            if self.cancel.as_ref().is_some_and(|f| f.load(std::sync::atomic::Ordering::Relaxed)) {
                return false;
            }
            // The camera took capture k at its first frame; `current` is
            // frame n, which may be a later repeat of it.
            let src: Cow<[u8]> = if timing.frame_of_capture(k) == n {
                Cow::Borrowed(current)
            } else {
                sensing.captured(timing.frame_of_capture(k)).map(Cow::Owned).unwrap_or(Cow::Borrowed(current))
            };
            self.advance(k, &src, geometry, timing, &sf.at(k), key, history);
        }
        false
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
            loss_pattern: LossPattern::from_raw(settings.get("loss_pattern").round() as i64).unwrap_or(LossPattern::Packets),
            concealment: Concealment::from_raw(settings.effective("concealment").round() as i64).unwrap_or(Concealment::LastPicture),
            bit_errors: settings.effective("bit_errors"),
            motion: settings.effective("mosh_motion").round() as i64,
            motion_speed: settings.effective("mosh_speed"),
            bits_per_pixel: settings.bits_per_pixel(),
            buffer_frames: swift_max(0.0, settings.get("rate_buffer")) * timing.capture_fps,
        };
        let (shown, step) = match settings.codec() {
            DigitalCodecKind::Dct => DigitalCodec::step(state, &picture, kind, k, &frame),
            DigitalCodecKind::BlockColors => (Video1Codec::step(state, &picture, kind, k, &frame), 0.0),
        };
        self.last_run_length += 1;
        self.last_capture = Some(k);
        self.shown = Self::present(&shown, geometry, settings, step);
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
        Self::fields(&Self::sense(base, width, height, row_bytes, size, optics), None, size, optics.fields())
    }

    /// The sensor's reading of one source frame (see `scale`), before the
    /// fields are put together. A one-chip sensor reads all three colors at
    /// the same place (there is no prism to offset them) and then sees only
    /// one of them at each pixel.
    pub fn sense(base: &[u8], width: usize, height: usize, row_bytes: usize, size: (usize, usize), optics: &DigitalSettings) -> Vec<u8> {
        let (cw, ch) = size;
        let one_chip = optics.get("sensor") >= 0.5;
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
                    let xr = if one_chip { xg } else { swift_min(width as i64 - 1, swift_max(0, (center - kx / 3.0) as i64)) as usize };
                    let xb = if one_chip { xg } else { swift_min(width - 1, (center + kx / 3.0) as usize) };
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
        match optics.sensor() {
            SensorKind::ThreeChips => {}
            SensorKind::Mosaic => Self::mosaic(&mut out, cw, ch),
            SensorKind::Complementary => Self::complementary(&mut out, cw, ch),
        }
        out
    }

    /// A one-chip sensor: a mosaic of color filters (red and green on even
    /// lines, green and blue on odd ones), so each pixel reads one color, and
    /// the camera fills in the other two from the nearest pixels that have
    /// them. Flat areas come out right; at an edge or in fine detail the
    /// three colors are guessed from different places, which shows as false
    /// color and a zipper along the edge.
    pub fn mosaic(rgba: &mut [u8], w: usize, h: usize) {
        if !(w >= 2 && h >= 2) {
            return;
        }
        let src = rgba.to_vec();
        // Neighbors past the edge are mirrored (keeping each one's color).
        let mx = |x: isize| -> usize { (if x < 0 { -x } else if x >= w as isize { 2 * w as isize - 2 - x } else { x }) as usize };
        let my = |y: isize| -> usize { (if y < 0 { -y } else if y >= h as isize { 2 * h as isize - 2 - y } else { y }) as usize };
        // Channel `c` (0 red, 1 green, 2 blue) at a pixel.
        let at = |x: isize, y: isize, c: usize| -> i64 { src[(my(y) * w + mx(x)) * 4 + c] as i64 };
        const RED: usize = 0;
        const GREEN: usize = 1;
        const BLUE: usize = 2;
        rgba.par_chunks_mut(w * 4).enumerate().for_each(|(y, o)| {
            let yi = y as isize;
            for x in 0..w {
                let xi = x as isize;
                let even_x = x % 2 == 0;
                let even_y = y % 2 == 0;
                let (r, g, b): (i64, i64, i64);
                if even_x == even_y {
                    // A red (even, even) or blue (odd, odd) pixel: green from
                    // the four beside it, the other color from the four
                    // diagonals.
                    let own = if even_x { RED } else { BLUE };
                    let other = if even_x { BLUE } else { RED };
                    g = (at(xi - 1, yi, GREEN) + at(xi + 1, yi, GREEN) + at(xi, yi - 1, GREEN) + at(xi, yi + 1, GREEN) + 2) / 4;
                    let d = (at(xi - 1, yi - 1, other) + at(xi + 1, yi - 1, other) + at(xi - 1, yi + 1, other) + at(xi + 1, yi + 1, other) + 2) / 4;
                    let mine = at(xi, yi, own);
                    r = if even_x { mine } else { d };
                    b = if even_x { d } else { mine };
                } else {
                    // A green pixel: red and blue from the two beside it,
                    // along the row or the column.
                    g = at(xi, yi, GREEN);
                    let across = if even_y { RED } else { BLUE };
                    let along = if even_y { BLUE } else { RED };
                    let a = (at(xi - 1, yi, across) + at(xi + 1, yi, across) + 1) / 2;
                    let c = (at(xi, yi - 1, along) + at(xi, yi + 1, along) + 1) / 2;
                    r = if even_y { a } else { c };
                    b = if even_y { c } else { a };
                }
                o[x * 4] = r as u8;
                o[x * 4 + 1] = g as u8;
                o[x * 4 + 2] = b as u8;
            }
        });
    }

    // MARK: - the camcorder's one chip (complementary filters)
    //
    // Most one-chip camcorders of the 90s didn't use red, green and blue
    // filters. Theirs were cyan, yellow, magenta and green — each passing two
    // thirds of the light instead of one — laid out
    //
    //     Cy Ye Cy Ye
    //     G  Mg G  Mg
    //     Cy Ye Cy Ye
    //     Mg G  Mg G
    //
    // and read two rows at a time, summed (field integration: one field pairs
    // rows 0+1, 2+3…, the other 1+2, 3+4…). Along a summed line the pixels
    // alternate between two sums, whose average is brightness (2R + 3G + 2B)
    // and whose difference is one color-difference signal: 2R − G on one
    // line, 2B − G on the field's next. Each line therefore has only one of
    // the two, and takes the other from the line before it in its field (a
    // one-line delay).
    //
    // Everything that makes these cameras look the way they do follows from
    // that, with nothing added: color has half the detail across and comes a
    // line late down the picture, so it smears and fringes at horizontal
    // edges; a sharp vertical edge reads as a difference between neighboring
    // pixels, which is what color is, so it picks up false color; brightness
    // is softened a little both ways by the sums.

    /// What the photosite at (x, y) reads of linear red, green and blue.
    #[inline(always)]
    pub fn complementary_site(x: isize, y: usize, r: f32, g: f32, b: f32) -> f32 {
        let even_x = x & 1 == 0;
        match y & 3 {
            // Cy, Ye
            0 | 2 => {
                if even_x { g + b } else { r + g }
            }
            // G, Mg
            1 => {
                if even_x { g } else { r + b }
            }
            // Mg, G
            _ => {
                if even_x { r + b } else { g }
            }
        }
    }

    /// Linear RGB from complementary photosites, as the camera forms it. The
    /// planes hold columns −2…w+2 and rows 0…h (`w + 5` by `h + 1`). Even
    /// lines read `even`, odd lines `odd`: the two fields are separate
    /// exposures, so their noise differs (a noise-free picture is passed as
    /// both).
    pub fn complementary_colors(even: &[f32], odd: &[f32], w: usize, h: usize) -> (Vec<f32>, Vec<f32>, Vec<f32>) {
        let pw = w + 5;
        let mut luma = vec![0f32; w * h];
        let mut color = vec![0f32; w * h]; // 2R − G or 2B − G, by line
        luma.par_chunks_mut(w).zip(color.par_chunks_mut(w)).enumerate().for_each(|(y, (l, c))| {
            let p = &(if y & 1 == 0 { even } else { odd })[y * pw..];
            // The line as read: each pixel and the one below it.
            let mut sum = vec![0f32; pw];
            for k in 0..pw {
                sum[k] = p[k] + p[k + pw];
            }
            // 2R − G lines pair an odd pixel less the even one before it;
            // 2B − G lines the other way.
            let red_line = y & 3 < 2;
            for x in 0..w {
                let k = x + 2;
                l[x] = (sum[k - 1] + 2.0 * sum[k] + sum[k + 1]) / 4.0;
                let mut acc = 0f32;
                for (j, weight) in [(k - 2, 1f32), (k - 1, 3.0), (k, 3.0), (k + 1, 1.0)] {
                    let step = sum[j + 1] - sum[j];
                    acc += weight * (if ((j as isize - 2) & 1 == 0) == red_line { step } else { -step });
                }
                c[x] = acc / 8.0;
            }
        });
        let mut r = vec![0f32; w * h];
        let mut g = vec![0f32; w * h];
        let mut b = vec![0f32; w * h];
        for y in 0..h {
            let red_line = y & 3 < 2;
            // The other color difference: the line before in this field.
            let from = if y >= 2 { y - 2 } else { y + 2 };
            for x in 0..w {
                let own = color[y * w + x];
                let other = color[from * w + x];
                let cr = if red_line { own } else { other };
                let cb = if red_line { other } else { own };
                let green = (2.0 * luma[y * w + x] - cr - cb) / 5.0;
                g[y * w + x] = green;
                r[y * w + x] = (cr + green) / 2.0;
                b[y * w + x] = (cb + green) / 2.0;
            }
        }
        (r, g, b)
    }

    /// A one-chip camcorder's reading of the picture (see above), in place.
    pub fn complementary(rgba: &mut [u8], w: usize, h: usize) {
        if !(w >= 4 && h >= 4) {
            return;
        }
        let pw = w + 5;
        let ph = h + 1;
        let mut sites = vec![0f32; pw * ph];
        for y in 0..ph {
            let sy = swift_min(h - 1, y);
            for k in 0..pw {
                let x = k as isize - 2;
                let i = (sy * w + swift_min(w as isize - 1, swift_max(0, x)) as usize) * 4;
                sites[y * pw + k] = Self::complementary_site(
                    x,
                    y,
                    srgb_to_linear(rgba[i] as usize),
                    srgb_to_linear(rgba[i + 1] as usize),
                    srgb_to_linear(rgba[i + 2] as usize),
                );
            }
        }
        let (r, g, b) = Self::complementary_colors(&sites, &sites, w, h);
        for i in 0..(w * h) {
            rgba[i * 4] = clampf(Self::linear_to_srgb(clampf(r[i], 0.0, 1.0)).round(), 0.0, 255.0) as u8;
            rgba[i * 4 + 1] = clampf(Self::linear_to_srgb(clampf(g[i], 0.0, 1.0)).round(), 0.0, 255.0) as u8;
            rgba[i * 4 + 2] = clampf(Self::linear_to_srgb(clampf(b[i], 0.0, 1.0)).round(), 0.0, 255.0) as u8;
        }
    }

    // MARK: - a one-chip sensor's grain

    /// Noise at a photosite for Sensor noise at 100%, on the 0–255 scale.
    /// Three chips' grain is 7 in brightness and 11 along each color signal —
    /// set by eye, stronger in color than three sensors' own noise would be
    /// (that would be about equal in all three: 0.67, 0.62 and 0.66 of the
    /// photosite's). So the two can't be matched part for part; this is the
    /// photosite noise with the same total energy:
    /// √((7² + 11² + 11²) / (0.67² + 0.62² + 0.66²)).
    pub const PHOTOSITE_NOISE: f32 = 15.1;

    /// Unit noise at every photosite, put through the sensor's own color
    /// reconstruction: what its grain looks like in red, green and blue.
    /// (The reconstruction is linear, so the picture's and the noise's can be
    /// made apart and added.) On one chip each color is pieced together from
    /// several photosites, so the grain isn't independent from pixel to
    /// pixel: color noise comes out in blotches a few pixels across — which
    /// color subsampling then can't average away — while brightness grain,
    /// summed over more light, is finer and weaker.
    pub fn sensor_grain(sensor: SensorKind, w: usize, h: usize, index: i64) -> Option<(Vec<f32>, Vec<f32>, Vec<f32>)> {
        let plane = |tag: u64, pw: usize, ph: usize| -> Vec<f32> {
            let mut out = vec![0f32; pw * ph];
            out.par_chunks_mut(pw).enumerate().for_each(|(y, o)| {
                let mut seeder = SplitMix::new(
                    (index as u64).wrapping_mul(0x2545_F491_4F6C_DD1D)
                        ^ (y as u64).wrapping_mul(0x9E37_79B9_7F4A_7C15)
                        ^ tag.wrapping_mul(0xD6E8_FEB8_6659_FD93),
                );
                let mut rng = SplitMix::new(seeder.next());
                for x in 0..pw {
                    let a = rng.unit();
                    let b = rng.unit();
                    o[x] = (a + b - 1.0) as f32 * 2.449;
                }
            });
            out
        };
        match sensor {
            SensorKind::ThreeChips => None,
            SensorKind::Mosaic => {
                if !(w >= 2 && h >= 2) {
                    return None;
                }
                Some(Self::mosaic_colors(&plane(1, w, h), w, h))
            }
            SensorKind::Complementary => {
                if !(w >= 4 && h >= 4) {
                    return None;
                }
                let even = plane(2, w + 5, h + 1);
                let odd = plane(3, w + 5, h + 1);
                Some(Self::complementary_colors(&even, &odd, w, h))
            }
        }
    }

    /// `mosaic`'s reconstruction on a plane of photosite values (for its
    /// grain): each color where it was read, else the mean of the nearest
    /// photosites that read it.
    pub fn mosaic_colors(site: &[f32], w: usize, h: usize) -> (Vec<f32>, Vec<f32>, Vec<f32>) {
        let mut r = vec![0f32; w * h];
        let mut g = vec![0f32; w * h];
        let mut b = vec![0f32; w * h];
        let mx = |x: isize| -> usize { (if x < 0 { -x } else if x >= w as isize { 2 * w as isize - 2 - x } else { x }) as usize };
        let my = |y: isize| -> usize { (if y < 0 { -y } else if y >= h as isize { 2 * h as isize - 2 - y } else { y }) as usize };
        let at = |x: isize, y: isize| -> f32 { site[my(y) * w + mx(x)] };
        for y in 0..h {
            for x in 0..w {
                let (xi, yi) = (x as isize, y as isize);
                let even_x = x % 2 == 0;
                let even_y = y % 2 == 0;
                let i = y * w + x;
                if even_x == even_y {
                    // A red (even, even) or blue (odd, odd) photosite.
                    let cross = (at(xi - 1, yi) + at(xi + 1, yi) + at(xi, yi - 1) + at(xi, yi + 1)) / 4.0;
                    let diagonal = (at(xi - 1, yi - 1) + at(xi + 1, yi - 1) + at(xi - 1, yi + 1) + at(xi + 1, yi + 1)) / 4.0;
                    g[i] = cross;
                    r[i] = if even_x { site[i] } else { diagonal };
                    b[i] = if even_x { diagonal } else { site[i] };
                } else {
                    // A green photosite: red and blue from the two beside it.
                    let across = (at(xi - 1, yi) + at(xi + 1, yi)) / 2.0;
                    let along = (at(xi, yi - 1) + at(xi, yi + 1)) / 2.0;
                    g[i] = site[i];
                    r[i] = if even_y { across } else { along };
                    b[i] = if even_y { along } else { across };
                }
            }
        }
        (r, g, b)
    }

    /// The frame the camera hands on, from what its sensor read: whole
    /// (progressive), one field with each line shown twice, or both fields of
    /// an interlaced frame — the even lines of this reading and the odd lines
    /// of the one `before` (the same reading when there is none, so a still
    /// picture is whole) — woven together or blended.
    pub fn fields(now: &[u8], before: Option<&[u8]>, size: (usize, usize), mode: FieldMode) -> Vec<u8> {
        let (cw, ch) = size;
        let row = cw * 4;
        let mut out = now.to_vec();
        match mode {
            FieldMode::Progressive => {}
            FieldMode::OneField => {
                // The even lines, each shown twice.
                let mut y = 1;
                while y < ch {
                    out.copy_within((y - 1) * row..y * row, y * row);
                    y += 2;
                }
            }
            FieldMode::Woven | FieldMode::Blended => {
                if let Some(before) = before.filter(|b| b.len() == now.len()) {
                    let mut y = 1;
                    while y < ch {
                        out[y * row..(y + 1) * row].copy_from_slice(&before[y * row..(y + 1) * row]);
                        y += 2;
                    }
                }
                if mode == FieldMode::Blended {
                    // A blend deinterlacer: each line mixed with the ones
                    // above and below, which belong to the other field
                    // (1-2-1).
                    let woven = out.clone();
                    out.par_chunks_mut(row).enumerate().for_each(|(y, o)| {
                        let up = &woven[swift_max(0, y as isize - 1) as usize * row..];
                        let mid = &woven[y * row..];
                        let down = &woven[swift_min(ch - 1, y + 1) * row..];
                        for i in 0..row {
                            o[i] = ((up[i] as i64 + 2 * mid[i] as i64 + down[i] as i64 + 2) / 4) as u8;
                        }
                    });
                }
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
        let curve = CcdResponse::new(settings.get("ccd_response") as f32);
        let mut gain_r = 1.0 + 0.25 * warm;
        let mut gain_b = 1.0 - 0.25 * warm;
        let mut gain_g = 1.0 - 0.15 * magenta;
        let mut flare = 0f32;
        // How far the camera has had to turn its gain up for this scene.
        let sensor_gain = if (low_light > 0.0 && noise > 0.0) || curve.exposure > 0.0 {
            Self::sensor_gain(Self::median_luma(rgba, w, h))
        } else {
            1.0
        };
        if low_light > 0.0 && noise > 0.0 {
            noise *= 1.0 + low_light * (sensor_gain - 1.0);
        }
        if curve.exposure > 0.0 {
            let exposure = curve.exposure_gain(Self::metered_mean(rgba, w, h, (gain_r, gain_g, gain_b)), sensor_gain);
            gain_r *= exposure;
            gain_g *= exposure;
            gain_b *= exposure;
        }
        if curve.flare > 0.0 {
            flare = curve.flare_light(Self::metered_mean(rgba, w, h, (gain_r, gain_g, gain_b)));
        }
        // A one-chip sensor's grain comes through its color reconstruction.
        let sensor = settings.sensor();
        let grain = if noise > 0.0 && sensor != SensorKind::ThreeChips { Self::sensor_grain(sensor, w, h, index) } else { None };
        // Vertical smear: the light each column's brightest pixels leak into
        // the whole column on its way off the chip.
        let smear = Self::smear(rgba, w, h, settings.get("smear") as f32);
        // Gains act on light, so they need linear values (decoded sRGB).
        let linear = gain_r != 1.0 || gain_g != 1.0 || gain_b != 1.0 || flare > 0.0 || smear.is_some() || curve.highlights > 0.0;
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
                        let veil = flare + smear.as_ref().map_or(0.0, |s| s[x]);
                        let over = curve.recovered(swift_max(swift_max(r, gr), b), swift_min(swift_min(r, gr), b));
                        r = Self::linear_to_srgb(srgb_to_linear(r as usize) * gain_r * over + veil);
                        gr = Self::linear_to_srgb(srgb_to_linear(gr as usize) * gain_g * over + veil);
                        b = Self::linear_to_srgb(srgb_to_linear(b as usize) * gain_b * over + veil);
                    }
                    if noise > 0.0 {
                        // Gain noise: worst in the shadows, and under the
                        // clip (a blown sky is clean).
                        let shade = 1.3 - 0.6 * swift_min(255.0, 0.299 * r + 0.587 * gr + 0.114 * b) / 255.0;
                        if let Some((grain_r, grain_g, grain_b)) = &grain {
                            let k = Self::PHOTOSITE_NOISE * noise * shade;
                            r += k * grain_r[i];
                            gr += k * grain_g[i];
                            b += k * grain_b[i];
                        } else {
                            let n = gauss() * 7.0 * noise * shade;
                            let nb = gauss() * 11.0 * noise * shade;
                            let nc = gauss() * 11.0 * noise * shade;
                            // Luma noise plus color noise along Cb and Cr.
                            r += n + 1.402 * nc;
                            gr += n - 0.344136 * nb - 0.714136 * nc;
                            b += n + 1.772 * nb;
                        }
                    }
                    if curve.highlights > 0.0 {
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
        let black = curve.black();
        let luma_scale = curve.luma_scale();
        let saturation = settings.get("saturation") as f32 * curve.chroma_scale();
        if black > 0.0 || saturation != 1.0 {
            for i in 0..yf.len() {
                yf[i] = black + yf[i] * luma_scale;
                cbf[i] = 128.0 + (cbf[i] - 128.0) * saturation;
                crf[i] = 128.0 + (crf[i] - 128.0) * saturation;
            }
        }
        Self::picture(&yf, &cbf, &crf, g)
    }

    /// Full-resolution Y′, Cb and Cr (`g.width` × `g.height`) as the picture
    /// the codec codes: padded to whole blocks, the color subsampled.
    pub fn picture(yf: &[f32], cbf: &[f32], crf: &[f32], g: &CodecGeometry) -> CodecPicture {
        let (w, h) = (g.width, g.height);
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

    /// A CCD's vertical smear, as light (linear) added to each column, or
    /// `None` for none. While a frame is shifted down the chip to be read
    /// out, every pixel passes under every other pixel of its column and
    /// picks up a little of the light falling there, so a spot bright enough
    /// to matter shows as a streak the full height of the picture. Sources
    /// are footage already exposed, so "bright enough" is what sits at the
    /// clip (sRGB 235 and up, counted in full at white); the streak follows
    /// that column's share of such pixels, a pixel either side mixed in — by
    /// its square root, since how far over white the light really was is
    /// lost, and a lamp a few pixels tall was far further over than a sky
    /// filling a third of the frame. A dark scene makes it stronger, as
    /// Low-light noise's gain does: the camera has opened up, and the lamp is
    /// that much further over white.
    pub fn smear(rgba: &[u8], w: usize, h: usize, strength: f32) -> Option<Vec<f32>> {
        if !(strength > 0.0 && w > 0 && h > 0) {
            return None;
        }
        let mut share = vec![0f32; w];
        for y in 0..h {
            for x in 0..w {
                let i = (y * w + x) * 4;
                let top = swift_max(swift_max(rgba[i], rgba[i + 1]), rgba[i + 2]);
                if top >= 235 {
                    share[x] += (top as i64 - 234) as f32 / 21.0;
                }
            }
        }
        let gain = Self::sensor_gain(Self::median_luma(rgba, w, h));
        let scale = strength * 1.25 * (gain / 8.0).sqrt();
        let mut out = vec![0f32; w];
        let mut any = false;
        for x in 0..w {
            let part = (share[swift_max(0, x as isize - 1) as usize] + 2.0 * share[x] + share[swift_min(w - 1, x + 1)]) / 4.0 / h as f32;
            let v = part.sqrt() * scale;
            out[x] = swift_min(1.0, v);
            if v > 0.0 {
                any = true;
            }
        }
        if any { Some(out) } else { None }
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

    /// What the viewer gets of the decoder's picture: rendered, then put
    /// through the Generations control's further rounds of compression.
    pub fn present(decoded: &CodecPicture, g: &CodecGeometry, settings: &DigitalSettings, step: f32) -> Vec<u8> {
        let mut out = Self::render(decoded, g, settings, step);
        let generations = settings.generations();
        if generations > 0 {
            for k in 1..=generations {
                out = Self::regenerate(&out, g, settings, k);
            }
        }
        out
    }

    /// One more generation: the decoded picture (RGBA at the capture size)
    /// compressed again at the same Quality, every frame on its own, and
    /// decoded — a video saved, cropped a little and uploaded again. The crop
    /// is what does the damage: compressing the same picture twice on the
    /// same blocks changes almost nothing the second time, but each
    /// generation's blocks fall a few pixels away from the last one's, so the
    /// old block edges are detail the new blocks have to spend on and get
    /// wrong. The offset depends only on the generation's number, so one more
    /// generation is one more pass on top of the same ones.
    pub fn regenerate(rgba: &[u8], g: &CodecGeometry, settings: &DigitalSettings, k: usize) -> Vec<u8> {
        let (w, h) = (g.width, g.height);
        // The grid to move against: the codec's blocks (Video 1's are 4×4).
        let grid = if settings.codec() == DigitalCodecKind::Dct { g.block } else { 4 };
        let dx = 1 + (2 * k) % (grid - 1);
        let dy = 1 + (4 * k + 1) % (grid - 1);
        // The picture with a margin, its content (dx, dy) in; the edge pixels
        // repeat into the margin.
        let padded = CodecGeometry::with_block(w + grid, h + grid, g.chroma, g.block);
        let (pw, ph) = (padded.width, padded.height);
        let mut yf = vec![0f32; pw * ph];
        let mut cbf = vec![0f32; pw * ph];
        let mut crf = vec![0f32; pw * ph];
        yf.par_chunks_mut(pw)
            .zip(cbf.par_chunks_mut(pw))
            .zip(crf.par_chunks_mut(pw))
            .enumerate()
            .for_each(|(y, ((yr, cbr), crr))| {
                let sy = swift_min(h as isize - 1, swift_max(0, y as isize - dy as isize)) as usize;
                for x in 0..pw {
                    let i = (sy * w + swift_min(w as isize - 1, swift_max(0, x as isize - dx as isize)) as usize) * 4;
                    let r = rgba[i] as f32;
                    let gr = rgba[i + 1] as f32;
                    let b = rgba[i + 2] as f32;
                    yr[x] = 0.299 * r + 0.587 * gr + 0.114 * b;
                    cbr[x] = 128.0 - 0.168736 * r - 0.331264 * gr + 0.5 * b;
                    crr[x] = 128.0 + 0.5 * r - 0.418688 * gr - 0.081312 * b;
                }
            });
        let source = Self::picture(&yf, &cbf, &crf, &padded);
        let mut step = 0f32;
        let coded: Arc<CodecPicture> = match settings.codec() {
            DigitalCodecKind::Dct => {
                let steps = Steps::with_block(settings.get("quality"), 1.0, g.block);
                let mut coded = CodecPicture::new(&padded);
                DigitalCodec::code_intra(&source, &mut coded, &steps);
                step = steps.inter;
                Arc::new(coded)
            }
            DigitalCodecKind::BlockColors => Video1Codec::step(
                &mut CodecState::new(padded),
                &source,
                CodecFrameKind::Key,
                0,
                &FrameSettings::new(settings.get("quality"), 0.0, 0.0),
            ),
        };
        let full = Self::render(&coded, &padded, settings, step);
        let mut out = vec![255u8; w * h * 4];
        for y in 0..h {
            let from = ((y + dy) * pw + dx) * 4;
            out[y * w * 4..(y + 1) * w * 4].copy_from_slice(&full[from..from + w * 4]);
        }
        out
    }

    /// The decoder's picture as RGBA8 at the capture size: deblocked (on a
    /// copy — the reference stays as coded), color interpolated back up.
    pub fn render(decoded: &CodecPicture, g: &CodecGeometry, settings: &DigitalSettings, step: f32) -> Vec<u8> {
        let deblocking = settings.effective("deblocking");
        let deblocked;
        let picture = if deblocking > 0.0 {
            let mut p = decoded.clone();
            DigitalCodec::deblock(&mut p, deblocking, step, g.block);
            deblocked = p;
            &deblocked
        } else {
            decoded
        };
        let (w, h) = (g.width, g.height);
        let mut out = vec![255u8; w * h * 4];
        let fx = g.sx() as f32;
        let fy = g.sy() as f32;
        let (sx, sy) = (g.sx(), g.sy());
        let (cb, cr, luma) = (&picture.cb, &picture.cr, &picture.y);
        // Color decode, Blocky: each color sample repeated over the pixels it
        // stands for, instead of interpolated.
        let blocky = settings.effective("chroma_upsampling") >= 0.5;
        out.par_chunks_mut(w * 4).enumerate().for_each(|(y, o)| {
            let cyf = (y as f32 + 0.5) / fy - 0.5;
            let cy0 = cyf.floor() as isize;
            let ty = cyf - cy0 as f32;
            for x in 0..w {
                let cxf = (x as f32 + 0.5) / fx - 0.5;
                let cx0 = cxf.floor() as isize;
                let tx = cxf - cx0 as f32;
                let bil = |p: &crate::codec::CodecPlane| -> f32 {
                    if blocky {
                        return p.clamped((x / sx) as isize, (y / sy) as isize);
                    }
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

/// A 90s DV camcorder's tone, in its four real parts. One slider (CCD
/// response) sets all four today; each has its own strength here, so they
/// can become separate controls without changing what they do.
///
/// The constants are fitted, not published: across six reference frames of
/// VX1000 footage the darkest pixels sat at 20–45 (not 0), medians at
/// 130–210, and 10–32% of each frame piled up in the top bins, with warm
/// shots' red reaching white well before blue. (Sony's specs stop at the
/// sensor; measuring a real camera needs footage straight off its tape.)
#[derive(Clone, Copy, Debug)]
pub struct CcdResponse {
    /// Auto exposure: how far the camera re-exposes the scene.
    pub exposure: f32,
    /// The knee and the clip: how hard highlights are squeezed.
    pub highlights: f32,
    /// Veiling flare from the lens.
    pub flare: f32,
    /// DV's levels shown as stored: black at 16, not 0.
    pub levels: f32,
}

impl CcdResponse {
    pub fn new(strength: f32) -> Self {
        CcdResponse { exposure: strength, highlights: strength, flare: strength, levels: strength }
    }

    pub fn is_on(&self) -> bool {
        self.exposure > 0.0 || self.highlights > 0.0 || self.flare > 0.0 || self.levels > 0.0
    }

    /// Auto exposure: bring the metered mean to a bright target — these
    /// cameras exposed for faces and shadows and let skies go. Stopping down
    /// is always possible. Opening up is only possible with the gain the
    /// camera has left: in a dark scene it is already wide open with its
    /// gain turned up (`sensor_gain`, 1 in daylight to its top of 8 at night,
    /// the same measure Low-light noise uses), so a night scene stays night
    /// instead of being pushed up to gray daylight.
    pub const TARGET: f32 = 0.40;
    pub const TOP_GAIN: f32 = 8.0;

    pub fn exposure_gain(&self, metered_mean: f32, sensor_gain: f32) -> f32 {
        let mut full = swift_min(4.0, swift_max(0.5, Self::TARGET / swift_max(metered_mean, 1e-4)));
        if full > 1.0 {
            full = swift_max(1.0, swift_min(full, Self::TOP_GAIN / swift_max(1.0, sensor_gain)));
        }
        full.powf(self.exposure)
    }

    /// Veiling flare from a cheap lens (and the fisheye adapters these were
    /// shot through): a share of the whole frame's light scattered over
    /// everything, so bright scenes lift their shadows most.
    pub fn flare_light(&self, metered_mean: f32) -> f32 {
        0.03 * self.flare * metered_mean
    }

    /// The knee: above it each channel is compressed, then clips at white.
    pub const KNEE_POINT: f32 = 0.72 * 255.0;

    pub fn knee_slope(&self) -> f32 {
        1.0 - 0.62 * self.highlights
    }

    pub fn knee(&self, v: f32) -> f32 {
        if !(v > Self::KNEE_POINT) {
            return v;
        }
        swift_min(255.0, Self::KNEE_POINT + (v - Self::KNEE_POINT) * self.knee_slope())
    }

    /// The light at which a channel clips, as a multiple of the source's
    /// white: where the knee's line reaches 255 (2.37 at full strength — 1.2
    /// stops of highlights squeezed in above the knee).
    pub fn clip_light(&self) -> f32 {
        let v = (Self::KNEE_POINT + (255.0 - Self::KNEE_POINT) / self.knee_slope()) / 255.0;
        ((v + 0.055) / 1.055).powf(2.4)
    }

    /// What's white in the source was brighter than white: the camera that
    /// shot it clipped there, and a lamp or the sun is far over. Such pixels
    /// (from sRGB 235, in full at 255) are taken to be as far over as this
    /// camera's own clip, so they clip here too. Without this the knee, which
    /// makes room above white for highlights the source no longer has, would
    /// turn every lamp and white wall gray whenever the exposure isn't pushed
    /// up. Only what is near white counts (by the square of its lowest
    /// channel against its highest): one channel at the top is a saturated
    /// color, a blue sky or a red sign, not a blown highlight. Returns the
    /// factor on the pixel's light, from its highest and lowest channels
    /// (0–255).
    pub fn recovered(&self, top: f32, low: f32) -> f32 {
        if !(self.highlights > 0.0 && top >= 235.0) {
            return 1.0;
        }
        let t = swift_min(1.0, (top - 234.0) / 21.0);
        let white = low / top;
        1.0 + (self.clip_light() - 1.0) * t * t * white * white
    }

    /// Levels. DV stores black at 16 and white at 235 of 255, and the camera
    /// records on past white to its clip at about 109% (255). Shown on a
    /// computer as stored, without stretching that range back out, black is
    /// a milky gray (16 of 255, 6.3%), the picture keeps its highlights right
    /// up to 255, and color comes out a few percent weak (its range is
    /// 16–240). That is the lifted black of DV footage on the web — it was
    /// fitted first as a 6.5% "setup" lift; this is where the number comes
    /// from.
    pub fn black(&self) -> f32 {
        16.0 * self.levels
    }

    /// (The clip, 109% of white, lands on 255: luma spans 16…255.)
    pub fn luma_scale(&self) -> f32 {
        1.0 - self.levels * 16.0 / 255.0
    }

    /// (Color's ±112 around 128 for 100%, so ±1.09 × 112 at the clip.)
    pub fn chroma_scale(&self) -> f32 {
        1.0 - self.levels * (1.0 - 1.09 * 224.0 / 255.0)
    }
}
