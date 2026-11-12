//! A clip's frames decoded ahead, in order, on a thread of their own (the
//! Mac's playback producer, for decoding): playback asks for frames a few
//! at a time ahead of the last, and a decoder that seeks for each of those
//! spends most of its time going back to keyframes. Here the thread keeps
//! reading on past the frame last asked for, so the next ones are ready;
//! a jump backward or far ahead seeks once.

use std::collections::VecDeque;
use std::path::Path;
use std::sync::{Arc, Condvar, Mutex};
use std::thread::JoinHandle;

use anyhow::{anyhow, Result};
use ntscrt_engine::Image;
use ntscrt_media::{VideoInfo, VideoReader};

/// Frames decoded past the one asked for.
const AHEAD: usize = 12;
/// Further than this past what's decoded, seek rather than read on.
const SEEK_PAST: usize = 24;

#[derive(Default)]
struct State {
    /// The frame last asked for.
    want: usize,
    /// Decoded frames, in order.
    ring: VecDeque<(usize, Arc<Image>)>,
    error: Option<String>,
    stop: bool,
}

pub struct Prefetch {
    shared: Arc<(Mutex<State>, Condvar)>,
    thread: Option<JoinHandle<()>>,
    info: VideoInfo,
}

impl Prefetch {
    pub fn open(path: &Path) -> Result<Self> {
        let shared: Arc<(Mutex<State>, Condvar)> = Arc::default();
        let (tx, rx) = std::sync::mpsc::channel();
        let path = path.to_path_buf();
        let s = shared.clone();
        let thread = std::thread::spawn(move || {
            let mut reader = match VideoReader::open(&path) {
                Ok(r) => r,
                Err(e) => {
                    let _ = tx.send(Err(e));
                    return;
                }
            };
            let info = reader.info();
            let _ = tx.send(Ok(info));
            run(&mut reader, info, &s);
        });
        let info = rx.recv().map_err(|_| anyhow!("the decoder stopped"))??;
        Ok(Self { shared, thread: Some(thread), info })
    }

    pub fn info(&self) -> VideoInfo {
        self.info
    }

    /// While playing: the newest frame decoded up to `index`, without
    /// waiting if there is one (playback drops what decoding can't keep up
    /// with), else frame `index`.
    pub fn frame_upto(&self, index: usize) -> Result<(usize, Arc<Image>)> {
        let index = index.min(self.info.total_frames.saturating_sub(1));
        {
            let (lock, cv) = &*self.shared;
            let mut st = lock.lock().expect("prefetch");
            if let Some((n, img)) = st.ring.iter().rev().find(|(n, _)| *n <= index && *n + SEEK_PAST >= index).cloned() {
                st.want = index;
                cv.notify_all();
                return Ok((n, img));
            }
        }
        Ok((index, self.frame(index)?))
    }

    /// Frame `index` (held to the clip), waiting for it if need be.
    pub fn frame(&self, index: usize) -> Result<Arc<Image>> {
        let index = index.min(self.info.total_frames.saturating_sub(1));
        let (lock, cv) = &*self.shared;
        let mut st = lock.lock().expect("prefetch");
        st.want = index;
        st.error = None;
        cv.notify_all();
        loop {
            if let Some((_, img)) = st.ring.iter().find(|(n, _)| *n == index) {
                return Ok(img.clone());
            }
            if let Some(e) = st.error.take() {
                return Err(anyhow!(e));
            }
            st = cv.wait(st).expect("prefetch");
        }
    }
}

impl Drop for Prefetch {
    fn drop(&mut self) {
        let (lock, cv) = &*self.shared;
        lock.lock().expect("prefetch").stop = true;
        cv.notify_all();
        if let Some(t) = self.thread.take() {
            let _ = t.join();
        }
    }
}

fn run(reader: &mut VideoReader, info: VideoInfo, shared: &(Mutex<State>, Condvar)) {
    let (lock, cv) = shared;
    let last = info.total_frames.saturating_sub(1);
    // The next frame this thread will decode.
    let mut pos: Option<usize> = None;
    loop {
        let next = {
            let mut st = lock.lock().expect("prefetch");
            loop {
                if st.stop {
                    return;
                }
                let want = st.want;
                // Drop what's behind the one asked for, but keep the newest
                // of those (playback shows it while decoding catches up)
                // and a frame or two before it.
                while st.ring.len() > 3 && st.ring[3].0 <= want {
                    st.ring.pop_front();
                }
                let have = |n: usize| st.ring.iter().any(|(m, _)| *m == n);
                // Off the decoded run (backward, or far ahead): start over there.
                let restart = match pos {
                    None => true,
                    Some(p) => want + 2 < st.ring.front().map_or(p, |f| f.0) || want > p + SEEK_PAST,
                };
                if restart && !have(want) {
                    st.ring.clear();
                    pos = Some(want);
                }
                let p = pos.expect("set");
                if p <= (want + AHEAD).min(last) && st.error.is_none() {
                    break p;
                }
                st = cv.wait(st).expect("prefetch");
            }
        };
        // Decode without holding the lock.
        let decoded = reader.frame(next);
        let mut st = lock.lock().expect("prefetch");
        match decoded {
            Ok(f) => {
                st.ring.push_back((next, Arc::new(Image::new(f.width, f.height, f.rgba))));
                pos = Some(next + 1);
            }
            Err(e) => {
                st.error = Some(format!("{e:#}"));
                pos = None;
            }
        }
        cv.notify_all();
    }
}
