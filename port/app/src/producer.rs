//! Playback's producer (the Mac's PlaybackPipeline): while a clip plays, a
//! thread of its own takes the decoded frames in order, crops them and runs
//! the CPU stages (Digital video, NTSC), a few frames ahead of the one
//! showing, so the render thread only does the GPU part. Done one after the
//! other on the render thread, a frame cost both; overlapped, it costs the
//! slower of the two.
//!
//! The Digital stage's codec carries state from frame to frame, so with it
//! on every frame goes through it in order: a producer a little behind
//! makes frames that show a little late; further behind, it runs only the
//! codec (no NTSC) for frames playback has passed, to catch up. Jumping
//! instead would re-run the codec from a keyframe, reading the frames
//! before it again. Without the stage, a producer that falls behind
//! jumps to the frame playback wants.

use std::collections::{HashSet, VecDeque};
use std::path::PathBuf;
use std::sync::{Arc, Condvar, Mutex};
use std::thread::JoinHandle;

use ntscrt_engine::codec::DigitalVideoRenderer;
use ntscrt_engine::crop::Crop;
use ntscrt_engine::{Image, Settings};

use crate::prefetch::Prefetch;

/// Frames made ahead of the one playback wants.
const AHEAD: usize = 3;
/// With Digital video: frames this far behind the one playback wants are
/// still made whole (they show a little late)...
const LAG: usize = 6;
/// ...further behind, up to this, only the codec runs; further still (a
/// seek, or a loop back to the start), the producer jumps.
const JUMP: usize = 90;
/// Catching up, a whole frame after this many codec-only ones.
const UNSEEN_RUN: usize = 3;

/// One frame: the cropped picture, and it through the CPU stages (None
/// when the frame cache already holds it baked).
pub struct Produced {
    pub frame: usize,
    pub clean: Image,
    pub processed: Option<Image>,
}

#[derive(Default)]
struct State {
    /// The frame playback wants now.
    want: usize,
    ready: VecDeque<Produced>,
    error: Option<String>,
    stop: bool,
}

pub struct Producer {
    shared: Arc<(Mutex<State>, Condvar)>,
    /// Gives the Digital stage's codec back when it ends.
    thread: Option<JoinHandle<DigitalVideoRenderer>>,
    /// What it was started with: the stamp of its settings and crop.
    pub stamp: u64,
    pub with_clean: bool,
    total: usize,
}

/// The settings for clip frame `n`: its noise seed and Digital frame.
pub fn settings_for_frame(template: &Settings, n: usize) -> Settings {
    let mut s = template.clone();
    s.frame = n + 1;
    if let Some(d) = s.digital.as_mut() {
        d.frame = n as i64;
    }
    s
}

impl Producer {
    /// Start at frame `from`. `cached`: frames the cache holds baked under
    /// these settings, whose CPU stages can be skipped.
    /// `with_clean`: the cropped picture is wanted even for cached frames
    /// (Compare). `digital`: the Digital stage's codec as the render thread
    /// left it, to carry on from (`finish` gives it back).
    #[allow(clippy::too_many_arguments)]
    pub fn start(reader: Arc<Prefetch>, clip: Option<PathBuf>, template: Settings, crop: Option<Crop>, stamp: u64, from: usize, cached: HashSet<usize>, with_clean: bool, digital: DigitalVideoRenderer) -> Self {
        let total = reader.info().total_frames.max(1);
        let shared: Arc<(Mutex<State>, Condvar)> = Arc::new((Mutex::new(State { want: from % total, ..Default::default() }), Condvar::new()));
        let s = shared.clone();
        let thread = std::thread::Builder::new()
            .name("playback producer".into())
            .spawn(move || {
                let mut digital = digital;
                run(&reader, clip, &template, crop, from, &cached, with_clean, &mut digital, &s);
                digital
            })
            .expect("producer thread");
        Self { shared, thread: Some(thread), stamp, with_clean, total }
    }

    /// The newest frame made up to `want` (older ones are dropped), waiting
    /// for one if there's none yet.
    pub fn take(&self, want: usize) -> anyhow::Result<Produced> {
        let (lock, cv) = &*self.shared;
        let mut st = lock.lock().expect("producer");
        st.want = want % self.total;
        cv.notify_all();
        let total = self.total;
        loop {
            let want = st.want;
            // The newest at or just before `want` (around the loop), else
            // one a little past it (playback rounded down).
            let usable = st.ready.iter().rposition(|p| behind(p.frame, want, total) <= JUMP);
            let i = usable.or_else(|| st.ready.iter().position(|p| ahead(p.frame, want, total) <= AHEAD));
            if let Some(i) = i {
                let p = st.ready.drain(..=i).next_back().expect("one");
                cv.notify_all();
                return Ok(p);
            }
            // Nothing near `want` (it jumped): make room for frames that are.
            st.ready.clear();
            if let Some(e) = st.error.take() {
                return Err(anyhow::anyhow!(e));
            }
            cv.notify_all();
            st = cv.wait(st).expect("producer");
        }
    }
}

/// How many frames `n` is before `want`, around a clip of `total` (0 = it).
fn behind(n: usize, want: usize, total: usize) -> usize {
    (want + total - n % total) % total
}

/// How many frames `n` is past `want`, around the clip.
fn ahead(n: usize, want: usize, total: usize) -> usize {
    (n % total + total - want) % total
}

impl Producer {
    /// Stop, and give back the Digital stage's codec.
    pub fn finish(mut self) -> DigitalVideoRenderer {
        self.stop().unwrap_or_default()
    }

    fn stop(&mut self) -> Option<DigitalVideoRenderer> {
        let (lock, cv) = &*self.shared;
        lock.lock().expect("producer").stop = true;
        cv.notify_all();
        self.thread.take().and_then(|t| t.join().ok())
    }
}

impl Drop for Producer {
    fn drop(&mut self) {
        self.stop();
    }
}

#[allow(clippy::too_many_arguments)]
fn run(reader: &Prefetch, clip: Option<PathBuf>, template: &Settings, crop: Option<Crop>, from: usize, cached: &HashSet<usize>, with_clean: bool, digital: &mut DigitalVideoRenderer, shared: &(Mutex<State>, Condvar)) {
    let (lock, cv) = shared;
    let total = reader.info().total_frames.max(1);
    let digital_on = template.digital.is_some();
    let ntsc_on = template.ntsc.is_some();
    // Codec-only frames since the last whole one.
    let mut unseen = 0;
    let profile = std::env::var_os("NTSCRT_PROFILE").is_some();
    // The Digital stage's earlier frames, for its re-runs (opened when needed).
    let mut earlier = if digital_on { clip.and_then(|p| crate::clip_frames::ClipFrames::open(&p, crop).ok()) } else { None };
    let mut next = from % total;
    loop {
        // Wait for room, then decide which frame is next and whether
        // playback has already passed it (only the codec needs it then).
        let (n, dropped) = {
            let mut st = lock.lock().expect("producer");
            loop {
                if st.stop {
                    return;
                }
                let want = st.want;
                let past = ahead(next, want, total);
                if past <= AHEAD {
                    if st.ready.len() <= AHEAD {
                        break (next, false);
                    }
                } else if past > AHEAD + 1 {
                    // Behind `want`, or it jumped.
                    // A little behind (or with NTSC off, when skipping it
                    // saves nothing): whole frames, shown late. Further:
                    // only the codec, but every few frames a whole one so
                    // the picture keeps moving.
                    let late = behind(next, want, total);
                    if digital_on && (late <= LAG || !ntsc_on) && late <= JUMP {
                        if st.ready.len() <= AHEAD {
                            break (next, false);
                        }
                    } else if digital_on && late <= JUMP {
                        unseen += 1;
                        if unseen > UNSEEN_RUN {
                            unseen = 0;
                            break (next, false);
                        }
                        break (next, true);
                    } else {
                        next = want;
                        continue;
                    }
                }
                // AHEAD past `want` already: wait for playback.
                st = cv.wait(st).expect("producer");
            }
        };
        // Baked already, and nothing else needed of it: playback takes it
        // from the cache, so there's nothing to make.
        if !digital_on && !with_clean && cached.contains(&n) {
            next = (n + 1) % total;
            continue;
        }
        let t = std::time::Instant::now();
        let mut decoded_ms = 0.0;
        let made = (|| -> anyhow::Result<Produced> {
            let pic = reader.frame(n)?;
            decoded_ms = t.elapsed().as_secs_f64() * 1000.0;
            let clean = match crop {
                Some(c) => c.apply(&pic),
                None => pic.as_ref().clone(),
            };
            let s = settings_for_frame(template, n);
            if !digital_on && cached.contains(&n) {
                return Ok(Produced { frame: n, clean, processed: None });
            }
            if dropped || cached.contains(&n) {
                // Only the codec, to keep its state.
                crate::clip_frames::with_visitor(&mut earlier, |v| ntscrt_engine::digital_unseen(digital, &s, &clean, v));
                return Ok(Produced { frame: n, clean, processed: None });
            }
            let mut processed = clean.clone();
            crate::clip_frames::with_visitor(&mut earlier, |v| ntscrt_engine::cpu_stages(digital, &s, &mut processed, v))?;
            Ok(Produced { frame: n, clean, processed: Some(processed) })
        })();
        if profile {
            let total = t.elapsed().as_secs_f64() * 1000.0;
            let what = if dropped { "codec only" } else { "whole" };
            eprintln!("profile producer {n} ({what}): decode {decoded_ms:.1} ms, CPU stages {:.1} ms, codec re-run {}", total - decoded_ms, digital.last_run_length);
        }
        let mut st = lock.lock().expect("producer");
        match made {
            Ok(p) => {
                // Frames playback has passed aren't queued; the rest are, in order.
                if !dropped {
                    st.ready.push_back(p);
                }
                next = (n + 1) % total;
            }
            Err(e) => {
                st.error = Some(format!("{e:#}"));
                cv.notify_all();
                drop(st);
                // Wait to be stopped or asked for something else.
                let mut st = lock.lock().expect("producer");
                let want = st.want;
                while !st.stop && st.want == want {
                    st = cv.wait(st).expect("producer");
                }
                next = st.want % total;
                continue;
            }
        }
        cv.notify_all();
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn distances_go_around_the_loop() {
        // A 100-frame clip: frame 98 is 3 before frame 1, and frame 2 one past it.
        assert_eq!(behind(98, 1, 100), 3);
        assert_eq!(ahead(2, 1, 100), 1);
        assert_eq!(behind(5, 5, 100), 0);
        assert_eq!(ahead(5, 5, 100), 0);
        // Frame 1 just after a wrap is far "behind" frame 98 the long way round.
        assert_eq!(behind(1, 98, 100), 97);
        assert_eq!(ahead(1, 98, 100), 3);
    }

    #[test]
    fn a_frames_settings_carry_its_seed_and_digital_frame() {
        let template = Settings { ntsc: None, downscale: None, shader: None, frame: 0, glitch: None, digital: None };
        let s = settings_for_frame(&template, 41);
        assert_eq!(s.frame, 42);
    }
}
