//! A clip's sound, played along with the picture the preview shows (the
//! Mac's `VideoAudio.swift`). No controls: it plays at the system volume
//! whenever the clip plays.
//!
//! The picture is the master. The window says when each frame goes on
//! screen (`VideoAudio::frame_shown`); `AudioSync` — the Mac's, line for
//! line — decides when the sound has to start again somewhere else or go
//! quiet; the output thread (audio_win.rs: the clip's first audio track
//! decoded to PCM by Media Foundation, written to the default output device
//! through WASAPI) keeps the sound on the line that gives it (`Line`).
//!
//! `NTSCRT_AUDIO_MUTE=1` runs everything and writes silence (checks);
//! `NTSCRT_AUDIO_OFF=1` makes no sound object at all. Builds for anything
//! but Windows have no decoder, so `VideoAudio::open` gives None there.

#![cfg_attr(not(windows), allow(dead_code))]

use std::path::Path;
use std::sync::atomic::{AtomicBool, AtomicU8, Ordering};
use std::sync::{Arc, Mutex};
use std::time::Instant;

/// What the sound should do, as `AudioSync` sees it.
#[derive(Clone, Copy, Debug, PartialEq)]
pub enum Action {
    None,
    /// Play from this media time (seconds), starting now.
    Play(f64),
    Silence,
}

/// Decides what a clip's sound does while its picture plays.
///
/// Playback shows frames on a wall-clock schedule, loops, seeks, and slows
/// down when a stage can't keep up (the Digital video codec). The sound
/// follows it. Told when each frame is shown, this keeps the line the sound
/// runs along (media time against the clock) and says when to move it:
///
///   - the picture jumped (a seek, the loop's wrap): start again there;
///   - the picture slipped behind the clock once (a stall): start again
///     where it is;
///   - it keeps slipping (playback slower than real time): be silent until
///     it has held real time for a while — sound that restarts several
///     times a second is worse than none.
///
/// No player in here, so it can be tested.
#[derive(Clone, Debug, Default)]
pub struct AudioSync {
    /// (clock, media) of the line's start.
    anchor: Option<(f64, f64)>,
    last_media: f64,
    last_slip: Option<f64>,
    /// When the picture last slipped (or playback began).
    steady_since: f64,
    silent: bool,
}

impl AudioSync {
    /// How far the picture may sit from the sound's line before the sound
    /// moves. Frames are shown within a display refresh of when they are
    /// due, so real-time playback stays well inside this.
    pub const TOLERANCE: f64 = 0.08;
    /// Two slips within this long means playback isn't real time.
    pub const SLIP_WINDOW: f64 = 5.0;
    /// Silent, the picture has to hold real time this long to get its
    /// sound back.
    pub const RESUME_AFTER: f64 = 2.0;

    pub fn new() -> Self {
        Self::default()
    }

    pub fn silent(&self) -> bool {
        self.silent
    }

    /// Forget where the sound was (playback stopped, or restarted somewhere
    /// else): the next frame starts it.
    pub fn reset(&mut self) {
        *self = Self::default();
    }

    /// A frame with this media time went on screen at `clock` (seconds, any
    /// steady clock).
    pub fn frame_shown(&mut self, media: f64, clock: f64) -> Action {
        let Some((a_clock, a_media)) = self.anchor else {
            self.anchor = Some((clock, media));
            self.last_media = media;
            self.steady_since = clock;
            return Action::Play(media);
        };
        let error = media - (a_media + (clock - a_clock));
        let backwards = media < self.last_media;
        self.last_media = media;
        let on_line = !backwards && error.abs() <= Self::TOLERANCE;
        if !on_line {
            self.anchor = Some((clock, media));
        }
        // Behind the clock without having gone backwards: the picture ran
        // slow. Anything else off the line is a jump (a seek, the loop's
        // wrap), which says nothing about speed.
        if !backwards && error < -Self::TOLERANCE {
            let again = self.last_slip.is_some_and(|s| clock - s <= Self::SLIP_WINDOW);
            self.last_slip = Some(clock);
            self.steady_since = clock;
            if self.silent {
                return Action::None;
            }
            if again {
                self.silent = true;
                return Action::Silence;
            }
            return Action::Play(media);
        }
        if self.silent {
            if clock - self.steady_since < Self::RESUME_AFTER {
                return Action::None;
            }
            self.silent = false;
            self.last_slip = None;
            self.anchor = Some((clock, media));
            return Action::Play(media);
        }
        if on_line { Action::None } else { Action::Play(media) }
    }
}

/// What the window last told the output thread.
#[derive(Clone, Copy, Debug, PartialEq)]
pub(crate) struct Command {
    /// Goes up with every play or silence, so the same media time asked for
    /// twice (a short loop's wrap) still starts the sound again.
    pub generation: u64,
    pub playing: bool,
    /// Play: this media time (seconds) belongs to this clock time.
    pub media: f64,
    pub at: f64,
    /// When a frame last went on screen.
    pub last_frame: f64,
}

impl Command {
    fn quiet() -> Self {
        Self { generation: 0, playing: false, media: 0.0, at: 0.0, last_frame: 0.0 }
    }
}

/// What the output thread does on one of its turns.
#[derive(Clone, Copy, Debug, PartialEq)]
pub(crate) enum Step {
    /// Nothing to play. `stop`: the device was running and has to be
    /// stopped and emptied.
    Idle { stop: bool },
    /// Empty the device and start from `Line::next`.
    Start,
    /// Write on from `Line::next`.
    Continue,
}

/// Where the sound is against where the picture puts it: the output
/// thread's bookkeeping, without a device, so it can be tested.
///
/// Positions are frames of the clip's own PCM (frame 0 = the sound's first
/// sample = media time zero). The sample written next is heard once what is
/// still queued in the device has played, plus the device's latency — so
/// that is the media time it has to be.
#[derive(Clone, Debug)]
pub(crate) struct Line {
    rate: f64,
    /// The PCM frame the next sample written is.
    pub next: i64,
    generation: u64,
    running: bool,
    /// Frames of fade-in still to go.
    fade: u32,
}

impl Line {
    /// Off the line by more than this (the device's clock against the
    /// computer's, a stalled thread), the sound jumps back onto it.
    pub const RESYNC: f64 = 0.04;
    /// Each start fades in over this long, so a jump doesn't click.
    pub const FADE: f64 = 0.005;
    /// No frame on screen for this long (a dialog open, the window stalled):
    /// quiet until the picture moves again.
    pub const WATCHDOG: f64 = 0.5;

    pub fn new(rate: u32) -> Self {
        Self { rate: rate.max(1) as f64, next: 0, generation: 0, running: false, fade: 0 }
    }

    /// The device went away: whatever comes next is a start.
    pub fn lost(&mut self) {
        self.running = false;
    }

    /// `queued`: frames written and not played yet. `latency`: the device's,
    /// seconds.
    pub fn step(&mut self, cmd: &Command, clock: f64, queued: u32, latency: f64) -> Step {
        let audible = cmd.playing && clock - cmd.last_frame <= Self::WATCHDOG;
        if !audible {
            let stop = self.running;
            self.running = false;
            self.generation = cmd.generation;
            return Step::Idle { stop };
        }
        let now = (cmd.media + (clock - cmd.at) + latency) * self.rate;
        if !self.running || cmd.generation != self.generation {
            self.running = true;
            self.generation = cmd.generation;
            self.next = now.round() as i64;
            self.fade = (Self::FADE * self.rate) as u32;
            return Step::Start;
        }
        let want = now + queued as f64;
        if (self.next as f64 - want).abs() > Self::RESYNC * self.rate {
            self.next = want.round() as i64;
            self.fade = (Self::FADE * self.rate) as u32;
        }
        Step::Continue
    }

    /// The media time being heard now (seconds), for the log.
    pub fn heard(&self, queued: u32, latency: f64) -> f64 {
        (self.next - queued as i64) as f64 / self.rate - latency
    }

    /// The next `out.len() / channels` frames from `pcm` (interleaved, as
    /// much of the clip's sound as is decoded so far): silence before the
    /// start, past the end and when `mute`.
    pub fn fill(&mut self, pcm: &[i16], channels: usize, mute: bool, out: &mut [i16]) {
        let channels = channels.max(1);
        let total = (pcm.len() / channels) as i64;
        let ramp = (Self::FADE * self.rate).max(1.0);
        for frame in out.chunks_exact_mut(channels) {
            let gain = if self.fade > 0 { 1.0 - self.fade as f64 / ramp } else { 1.0 };
            self.fade = self.fade.saturating_sub(1);
            if mute || self.next < 0 || self.next >= total {
                frame.fill(0);
            } else {
                let at = self.next as usize * channels;
                for (o, s) in frame.iter_mut().zip(&pcm[at..at + channels]) {
                    *o = if gain >= 1.0 { *s } else { (*s as f64 * gain) as i16 };
                }
            }
            self.next += 1;
        }
    }
}

/// More than two channels (5.1 and the like) come down to stereo: the
/// front pair, with the center and each side's surround at −3 dB. In place;
/// returns the new length.
pub(crate) fn downmix(samples: &mut [i16], channels: usize) -> usize {
    if channels <= 2 {
        return samples.len();
    }
    let frames = samples.len() / channels;
    for f in 0..frames {
        let s = &samples[f * channels..(f + 1) * channels];
        let center = s[2] as f32 * 0.7071;
        // 5.1 and 7.1 order: FL FR FC LFE then the surrounds in pairs.
        let (mut l, mut r) = (s[0] as f32 + center, s[1] as f32 + center);
        let mut k = 4;
        while k + 1 < channels {
            l += s[k] as f32 * 0.7071;
            r += s[k + 1] as f32 * 0.7071;
            k += 2;
        }
        samples[f * 2] = l.clamp(-32768.0, 32767.0) as i16;
        samples[f * 2 + 1] = r.clamp(-32768.0, 32767.0) as i16;
    }
    frames * 2
}

/// The clip's sound as PCM, filling up while it is decoded.
pub(crate) struct Pcm {
    pub rate: u32,
    /// As stored here (1 or 2).
    pub channels: u16,
    pub samples: Mutex<Vec<i16>>,
}

/// The longest sound kept (seconds): a clip's whole sound is held decoded
/// in memory (115 MB for this much at 48 kHz stereo), and a clip longer
/// than this plays silent past it.
pub const LONGEST: f64 = 600.0;

const OPENING: u8 = 0;
const READY: u8 = 1;
const NONE: u8 = 2;

/// What the window and the sound's threads share.
pub(crate) struct Shared {
    pub command: Mutex<Command>,
    /// (clock, media time heard then) while the device plays.
    pub heard: Mutex<Option<(f64, f64)>>,
    state: AtomicU8,
    pub quit: AtomicBool,
    pub mute: bool,
    epoch: Instant,
}

impl Shared {
    fn new() -> Arc<Self> {
        Arc::new(Self {
            command: Mutex::new(Command::quiet()),
            heard: Mutex::new(None),
            state: AtomicU8::new(OPENING),
            quit: AtomicBool::new(false),
            mute: std::env::var("NTSCRT_AUDIO_MUTE").as_deref() == Ok("1"),
            epoch: Instant::now(),
        })
    }
    /// Seconds on the clock every part of this uses.
    pub fn clock(&self) -> f64 {
        self.epoch.elapsed().as_secs_f64()
    }
    pub fn quitting(&self) -> bool {
        self.quit.load(Ordering::Relaxed)
    }
    /// The clip has sound, and it is being decoded.
    pub fn set_ready(&self) {
        self.state.store(READY, Ordering::Relaxed);
    }
    /// The clip has no sound (or none that can be played).
    pub fn set_none(&self) {
        self.state.store(NONE, Ordering::Relaxed);
    }
}

/// Where a clip's sound stands, for the log.
#[derive(Clone, Copy, Debug, PartialEq)]
pub enum Status {
    /// The file is still being opened.
    Opening,
    /// The clip has no sound.
    NoSound,
    /// Quiet: the picture is slower than real time.
    Silenced,
    /// Not playing (paused, no output device, or about to start).
    NotPlaying,
    /// Playing, this far from where the picture puts it (seconds, + = the
    /// sound ahead).
    Playing(f64),
}

/// A clip's sound, following the frames the window shows. Driven from the
/// window's thread; nothing here waits on the file or the device.
pub struct VideoAudio {
    sync: AudioSync,
    shared: Arc<Shared>,
}

impl VideoAudio {
    /// The sound of the clip at `path`. The file is opened and decoded on a
    /// thread of its own; a clip without sound just never plays any. None
    /// with `NTSCRT_AUDIO_OFF=1`, and in builds for anything but Windows.
    pub fn open(path: &Path) -> Option<Self> {
        if std::env::var("NTSCRT_AUDIO_OFF").as_deref() == Ok("1") {
            return None;
        }
        #[cfg(windows)]
        {
            let shared = Shared::new();
            crate::audio_win::start(path.to_path_buf(), shared.clone());
            Some(Self { sync: AudioSync::new(), shared })
        }
        #[cfg(not(windows))]
        {
            let _ = path;
            None
        }
    }

    /// The picture just showed the frame at this media time (seconds).
    pub fn frame_shown(&mut self, media_time: f64) {
        self.frame_shown_at(media_time, Instant::now());
    }

    /// The frame at this media time belongs on screen at `when` — which may
    /// be a little before or after now: a window that picks each frame by
    /// the clock and shows it a render later knows when the frame was due
    /// more steadily than when it arrived, and a frame that arrives late
    /// isn't a picture running slow.
    pub fn frame_shown_at(&mut self, media_time: f64, when: Instant) {
        let now = self.shared.clock();
        let clock = if when >= self.shared.epoch {
            when.duration_since(self.shared.epoch).as_secs_f64()
        } else {
            -self.shared.epoch.duration_since(when).as_secs_f64()
        };
        let action = self.sync.frame_shown(media_time, clock);
        let Ok(mut c) = self.shared.command.lock() else { return };
        c.last_frame = now;
        match action {
            Action::None => {}
            Action::Play(t) => {
                *c = Command { generation: c.generation + 1, playing: true, media: t.max(0.0), at: clock, last_frame: now };
            }
            Action::Silence => {
                c.generation += 1;
                c.playing = false;
            }
        }
    }

    /// The picture is about to start somewhere else, or has stopped: quiet
    /// until its next frame.
    pub fn restart(&mut self) {
        self.sync.reset();
        if let Ok(mut c) = self.shared.command.lock() {
            c.generation += 1;
            c.playing = false;
        }
    }

    pub fn stop(&mut self) {
        self.restart();
    }

    /// For the playback log: where the sound is against the frame just
    /// shown (at `media_time`).
    pub fn status(&self, media_time: f64) -> Status {
        match self.shared.state.load(Ordering::Relaxed) {
            OPENING => return Status::Opening,
            NONE => return Status::NoSound,
            _ => {}
        }
        if self.sync.silent() {
            return Status::Silenced;
        }
        match self.shared.heard.lock().ok().and_then(|h| *h) {
            Some((clock, heard)) => Status::Playing(heard + (self.shared.clock() - clock) - media_time),
            None => Status::NotPlaying,
        }
    }

    #[cfg(test)]
    fn detached() -> Self {
        Self { sync: AudioSync::new(), shared: Shared::new() }
    }
}

impl Drop for VideoAudio {
    fn drop(&mut self) {
        self.shared.quit.store(true, Ordering::Relaxed);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Show `count` frames at `fps`, the picture running at `speed` × real
    /// time, from media time `from` and clock time `clock`. Returns what
    /// the sound was told, with the clock time of each instruction.
    fn play(sync: &mut AudioSync, from: f64, clock: f64, speed: f64, count: usize) -> Vec<(f64, Action)> {
        let fps = 30.0;
        let mut out = Vec::new();
        for i in 0..count {
            let h = clock + i as f64 / (fps * speed);
            let action = sync.frame_shown(from + i as f64 / fps, h);
            if action != Action::None {
                out.push((h, action));
            }
        }
        out
    }

    // The Mac's VideoAudioTests, case for case.

    #[test]
    fn the_sound_starts_with_the_first_frame_and_is_left_alone_at_real_time() {
        let mut sync = AudioSync::new();
        let told = play(&mut sync, 2.5, 100.0, 1.0, 300);
        assert_eq!(told.len(), 1);
        assert_eq!(told[0].1, Action::Play(2.5));
        assert!(!sync.silent());
    }

    /// Frames arrive a little early or late (a display refresh, a busy
    /// moment) and some are dropped; none of that moves the sound.
    #[test]
    fn jitter_and_dropped_frames_dont_move_the_sound() {
        let mut sync = AudioSync::new();
        let mut moves = 0;
        for i in (0..300).filter(|i| i % 3 != 1) {
            let jitter = ((i * 7919) % 41 - 20) as f64 / 1000.0; // ±20 ms
            if sync.frame_shown(i as f64 / 30.0, 50.0 + i as f64 / 30.0 + jitter) != Action::None {
                moves += 1;
            }
        }
        assert_eq!(moves, 1, "only the start");
    }

    #[test]
    fn a_loop_wrap_or_a_seek_starts_the_sound_there() {
        let mut sync = AudioSync::new();
        play(&mut sync, 0.0, 100.0, 1.0, 60); // 0…2 s
        // The clip wraps: the next frame is the first again.
        assert_eq!(sync.frame_shown(0.0, 102.0), Action::Play(0.0));
        // A seek forward.
        assert_eq!(sync.frame_shown(7.0, 102.033), Action::Play(7.0));
        assert!(!sync.silent(), "jumps say nothing about speed");
    }

    /// A clip shorter than a second wraps several times a second; that must
    /// not read as playback running slow.
    #[test]
    fn a_short_loop_keeps_its_sound() {
        let mut sync = AudioSync::new();
        let mut clock = 10.0;
        for _ in 0..20 {
            for i in 0..12 {
                // 0.4 s at 30 fps
                let action = sync.frame_shown(i as f64 / 30.0, clock);
                assert_ne!(action, Action::Silence);
                if i == 0 {
                    assert_eq!(action, Action::Play(0.0));
                }
                clock += 1.0 / 30.0;
            }
        }
        assert!(!sync.silent());
    }

    #[test]
    fn one_stall_restarts_the_sound_where_the_picture_is() {
        let mut sync = AudioSync::new();
        play(&mut sync, 0.0, 100.0, 1.0, 30); // 0…1 s
        // Half a second goes by with nothing shown, then the next frame.
        assert_eq!(sync.frame_shown(1.0, 101.5), Action::Play(1.0));
        let after = play(&mut sync, 1.0 + 1.0 / 30.0, 101.5 + 1.0 / 30.0, 1.0, 300);
        assert!(after.is_empty());
        assert!(!sync.silent());
    }

    /// Playback slower than real time (the Digital video codec can't keep
    /// up): the sound goes quiet rather than restart several times a second.
    #[test]
    fn a_picture_running_slow_goes_silent() {
        let mut sync = AudioSync::new();
        let told = play(&mut sync, 0.0, 100.0, 0.6, 600);
        assert!(sync.silent());
        assert_eq!(told.last().unwrap().1, Action::Silence);
        // It starts, restarts once at the first slip, and goes quiet at the
        // second — within a second at this speed.
        assert_eq!(told.len(), 3);
        assert!(told.last().unwrap().0 - 100.0 < 1.0);
    }

    #[test]
    fn the_sound_comes_back_once_the_picture_holds_real_time() {
        let mut sync = AudioSync::new();
        play(&mut sync, 0.0, 100.0, 0.6, 120);
        assert!(sync.silent());
        // Real time from here (say the loop now plays from the frame cache).
        let clock = 100.0 + 120.0 / (30.0 * 0.6);
        let told = play(&mut sync, 4.0, clock, 1.0, 150);
        assert_eq!(told.len(), 1);
        let Action::Play(at) = told[0].1 else { panic!("{:?}", told[0]) };
        assert!((at - (4.0 + (told[0].0 - clock))).abs() < 1e-9, "it starts where the picture is by then");
        assert!((told[0].0 - clock - AudioSync::RESUME_AFTER).abs() <= 0.1);
        assert!(!sync.silent());
    }

    /// Slightly slow counts too: it slips past the tolerance again and again.
    #[test]
    fn slightly_slow_playback_goes_silent_too() {
        let mut sync = AudioSync::new();
        play(&mut sync, 0.0, 100.0, 0.95, 300);
        assert!(sync.silent());
    }

    #[test]
    fn reset_forgets_everything() {
        let mut sync = AudioSync::new();
        play(&mut sync, 0.0, 100.0, 0.5, 120);
        assert!(sync.silent());
        sync.reset();
        assert!(!sync.silent());
        assert_eq!(sync.frame_shown(3.0, 500.0), Action::Play(3.0));
    }

    // The output thread's bookkeeping.

    const RATE: u32 = 48_000;

    fn playing(media: f64, at: f64) -> Command {
        Command { generation: 1, playing: true, media, at, last_frame: at }
    }

    /// A device that plays what it is given in real time: run the output
    /// thread's loop against it, a turn every `turn` seconds, with frames
    /// going on screen all the while. Returns each turn's (clock, first PCM
    /// frame written, frames written, step).
    fn run(line: &mut Line, cmd: &Command, from: f64, seconds: f64, turn: f64, latency: f64, drift: f64) -> Vec<(f64, i64, u32, Step)> {
        let target = (0.08 * RATE as f64) as u32;
        let (mut queued, mut clock, mut out) = (0f64, from, Vec::new());
        while clock < from + seconds {
            let cmd = Command { last_frame: clock, ..*cmd };
            let step = line.step(&cmd, clock, queued.round() as u32, latency);
            if step == Step::Start {
                queued = 0.0;
            }
            let (first, mut wrote) = (line.next, 0);
            if step != (Step::Idle { stop: false }) && step != (Step::Idle { stop: true }) {
                wrote = target.saturating_sub(queued.round() as u32);
                let mut buf = vec![0i16; wrote as usize * 2];
                line.fill(&[], 2, false, &mut buf);
                queued += wrote as f64;
            }
            out.push((clock, first, wrote, step));
            clock += turn;
            // The device's clock runs `drift` faster than the computer's.
            queued = (queued - turn * RATE as f64 * (1.0 + drift)).max(0.0);
        }
        out
    }

    #[test]
    fn the_first_sample_is_the_one_due_when_it_is_heard() {
        let mut line = Line::new(RATE);
        // Media time 2 s went on screen at clock 10; the thread's turn
        // comes 4 ms later, and the device takes 20 ms to sound a sample.
        let cmd = playing(2.0, 10.0);
        assert_eq!(line.step(&cmd, 10.004, 0, 0.020), Step::Start);
        assert_eq!(line.next, ((2.0 + 0.004 + 0.020) * RATE as f64).round() as i64);
        assert!((line.heard(0, 0.020) - 2.004).abs() < 1e-4);
    }

    #[test]
    fn a_steady_device_is_written_to_without_a_gap_or_a_jump() {
        let mut line = Line::new(RATE);
        let turns = run(&mut line, &playing(0.0, 5.0), 5.0, 20.0, 0.0101, 0.015, 0.0);
        assert_eq!(turns[0].3, Step::Start);
        let mut expect = turns[0].1;
        for (clock, first, wrote, step) in &turns {
            assert_eq!(*first, expect, "at {clock}: every sample follows the one before");
            expect += *wrote as i64;
            if *clock > 5.0 {
                assert_eq!(*step, Step::Continue);
            }
        }
        // And still on the line 20 s on: what is heard is where the picture is.
        let (clock, first, wrote, _) = turns[turns.len() - 1];
        let heard = (first + wrote as i64 - (0.08 * RATE as f64) as i64) as f64 / RATE as f64 - 0.015;
        assert!((heard - (clock - 5.0)).abs() < 0.002, "{heard} at {clock}");
    }

    #[test]
    fn a_device_running_fast_is_pulled_back_onto_the_line_in_steps() {
        let mut line = Line::new(RATE);
        // 1% fast: 40 ms off after four seconds.
        let turns = run(&mut line, &playing(0.0, 0.0), 0.0, 30.0, 0.01, 0.0, 0.01);
        let mut jumps = Vec::new();
        let mut expect = turns[0].1;
        for (clock, first, wrote, _) in &turns {
            if *first != expect {
                jumps.push((*clock, (*first - expect) as f64 / RATE as f64));
            }
            expect = *first + *wrote as i64;
            // Never further off than the limit plus a turn's worth.
            let want = *clock * RATE as f64;
            let at = (*first - (0.08 * RATE as f64) as i64 + *wrote as i64) as f64;
            assert!((at - want).abs() < (Line::RESYNC + 0.02) * RATE as f64, "at {clock}");
        }
        assert!((6..=9).contains(&jumps.len()), "{jumps:?}");
        assert!(jumps.iter().all(|(_, by)| *by < 0.0 && by.abs() < 0.06), "back, by about the limit: {jumps:?}");
    }

    #[test]
    fn a_new_instruction_starts_again_even_at_the_same_media_time() {
        let mut line = Line::new(RATE);
        let mut cmd = playing(0.0, 1.0);
        assert_eq!(line.step(&cmd, 1.0, 0, 0.0), Step::Start);
        assert_eq!(line.step(&cmd, 1.01, 3000, 0.0), Step::Continue);
        // A short loop wraps: media time zero again.
        cmd = Command { generation: 2, at: 1.4, last_frame: 1.4, ..cmd };
        assert_eq!(line.step(&cmd, 1.4, 3000, 0.0), Step::Start);
        assert_eq!(line.next, 0);
    }

    #[test]
    fn silence_and_a_stalled_picture_stop_the_device_once() {
        let mut line = Line::new(RATE);
        let cmd = playing(0.0, 0.0);
        assert_eq!(line.step(&cmd, 0.0, 0, 0.0), Step::Start);
        // No frame on screen for over half a second (a file dialog is open).
        assert_eq!(line.step(&cmd, 0.4, 100, 0.0), Step::Continue);
        assert_eq!(line.step(&cmd, 0.6, 100, 0.0), Step::Idle { stop: true });
        assert_eq!(line.step(&cmd, 0.7, 0, 0.0), Step::Idle { stop: false });
        // The picture moves again, on its schedule: the sound is back on
        // the same line without being told.
        let cmd = Command { last_frame: 3.0, ..cmd };
        assert_eq!(line.step(&cmd, 3.0, 0, 0.0), Step::Start);
        assert_eq!(line.next, 3 * RATE as i64);
        // Told to be quiet.
        let quiet = Command { generation: 2, playing: false, ..cmd };
        assert_eq!(line.step(&quiet, 3.01, 500, 0.0), Step::Idle { stop: true });
    }

    #[test]
    fn the_sound_is_copied_from_where_the_line_is_and_silent_outside_it() {
        let pcm: Vec<i16> = (0..2000).map(|i| 1000 + i as i16).collect(); // 1000 stereo frames
        let mut line = Line::new(RATE);
        line.next = 998;
        let mut out = [7i16; 8];
        line.fill(&pcm, 2, false, &mut out);
        assert_eq!(out, [2996, 2997, 2998, 2999, 0, 0, 0, 0], "past the end: silence");
        assert_eq!(line.next, 1002);
        line.next = -2;
        line.fill(&pcm, 2, false, &mut out);
        assert_eq!(out, [0, 0, 0, 0, 1000, 1001, 1002, 1003], "before the start: silence");
        line.next = 10;
        line.fill(&pcm, 2, true, &mut out);
        assert_eq!(out, [0; 8], "muted");
        assert_eq!(line.next, 14, "and still moving");
    }

    #[test]
    fn a_start_fades_in() {
        let pcm = vec![10_000i16; 48_000];
        let mut line = Line::new(RATE);
        assert_eq!(line.step(&playing(0.1, 0.0), 0.0, 0, 0.0), Step::Start);
        let mut out = vec![0i16; 480];
        line.fill(&pcm, 1, false, &mut out);
        assert_eq!(out[0], 0);
        assert!(out.windows(2).all(|w| w[0] <= w[1]), "rising");
        assert!((4000..6000).contains(&out[120]), "half way after 2.5 ms: {}", out[120]);
        assert_eq!(out[240], 10_000, "full after 5 ms");
    }

    #[test]
    fn surround_comes_down_to_stereo() {
        // FL FR FC LFE SL SR
        let mut s = [1000i16, 2000, 100, 9999, 10, 20, 30000, -30000, 30000, 0, 30000, -30000];
        let n = downmix(&mut s, 6);
        assert_eq!(n, 4);
        assert_eq!(&s[..2], &[1077, 2084]);
        assert_eq!(&s[2..4], &[32767, -30000 + 21213 - 21213], "clipped, not wrapped");
        let mut stereo = [1i16, 2, 3, 4];
        assert_eq!(downmix(&mut stereo, 2), 4);
        assert_eq!(stereo, [1, 2, 3, 4]);
    }

    /// Frames that arrive unevenly (a slow GPU: a render or two late, now
    /// and then) but are told by when they were due keep the sound on one
    /// line: one start, never silenced. Told by when they arrived, the same
    /// frames read as a picture running slow.
    #[test]
    fn frames_told_by_when_they_were_due_keep_one_line() {
        let late = |k: usize| if k % 7 == 3 { 0.25 } else { 0.1 };
        let mut due = VideoAudio::detached();
        let start = Instant::now();
        for k in 0..120 {
            let t = k as f64 / 8.0; // 8 frames a second shown
            due.frame_shown_at(t, start + std::time::Duration::from_secs_f64(t + 0.1));
        }
        assert!(!due.sync.silent());
        assert_eq!(due.shared.command.lock().unwrap().generation, 1, "one start");
        let mut arrived = AudioSync::new();
        let mut silenced = false;
        for k in 0..120 {
            let t = k as f64 / 8.0;
            silenced |= arrived.frame_shown(t, t + late(k)) == Action::Silence;
        }
        assert!(silenced, "the uneven arrivals this is for");
    }

    #[test]
    fn the_window_side_turns_frames_into_instructions() {
        let mut a = VideoAudio::detached();
        assert_eq!(a.status(0.0), Status::Opening);
        a.shared.set_ready();
        a.frame_shown(1.5);
        let c = *a.shared.command.lock().unwrap();
        assert!(c.playing);
        assert_eq!((c.generation, c.media), (1, 1.5));
        assert_eq!(a.status(1.5), Status::NotPlaying, "nothing heard yet");
        *a.shared.heard.lock().unwrap() = Some((a.shared.clock(), 1.52));
        let Status::Playing(off) = a.status(1.5) else { panic!() };
        assert!((off - 0.02).abs() < 0.01);
        a.stop();
        let c = *a.shared.command.lock().unwrap();
        assert!(!c.playing);
        assert_eq!(c.generation, 2);
        // The next frame starts it again.
        a.frame_shown(0.0);
        assert!(a.shared.command.lock().unwrap().playing);
        a.shared.set_none();
        assert_eq!(a.status(0.0), Status::NoSound);
        let shared = a.shared.clone();
        drop(a);
        assert!(shared.quitting());
    }
}
