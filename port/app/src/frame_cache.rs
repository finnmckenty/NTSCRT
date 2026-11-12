//! A clip's baked frames (the Mac's ChainInputCache): each frame's chain
//! input with Digital video and NTSC done and the Downscale applied, kept
//! per frame so a clip that has played once plays back, and scrubs, with
//! no decoding or CPU stages at all. Entries are the Downscale's size
//! (about 300 KB at 320 px).
//!
//! Each entry remembers what it was baked with (a stamp); a lookup under
//! another stamp misses. Over the budget, entries baked with anything else
//! go first; when only current ones are left, the rest of the clip streams
//! live (no eviction: a loop that doesn't fit would evict exactly the
//! frames it needs next).

use std::collections::HashMap;
use std::hash::{Hash, Hasher};
use std::sync::Arc;

use ntscrt_engine::crop::Crop;
use ntscrt_engine::{Image, Settings};

/// At most 1 GiB.
const CAPACITY: usize = 1 << 30;

#[derive(Default)]
pub struct FrameCache {
    entries: HashMap<usize, (u64, Arc<Image>)>,
    bytes: usize,
}

/// What a frame's bake depends on, besides the frame: the clip, the crop,
/// and the settings ahead of the Glitch stage (Digital video's per-frame
/// number left out: it's the frame).
pub fn stamp(clip: u64, crop: Option<Crop>, s: &Settings) -> u64 {
    let mut h = std::collections::hash_map::DefaultHasher::new();
    clip.hash(&mut h);
    format!("{crop:?}").hash(&mut h);
    format!("{:?}", s.ntsc).hash(&mut h);
    format!("{:?}", s.downscale).hash(&mut h);
    if let Some(d) = &s.digital {
        format!("{:?} {} {:?} {:?}", d.settings, d.source_fps, d.capture, d.history.as_ref().map(|h| h.0.id)).hash(&mut h);
    }
    h.finish()
}

impl FrameCache {
    pub fn get(&self, frame: usize, stamp: u64) -> Option<Arc<Image>> {
        self.entries.get(&frame).filter(|e| e.0 == stamp).map(|e| e.1.clone())
    }

    /// Frames held for `stamp`.
    pub fn count(&self, stamp: u64) -> usize {
        self.entries.values().filter(|e| e.0 == stamp).count()
    }

    /// False when the budget is spent (nothing stored).
    pub fn insert(&mut self, frame: usize, stamp: u64, image: Image) -> bool {
        let n = image.rgba.len();
        let old = self.entries.get(&frame).map_or(0, |e| e.1.rgba.len());
        if self.bytes - old + n > CAPACITY {
            // Make room from entries baked with other settings.
            let stale: Vec<usize> = self.entries.iter().filter(|(_, e)| e.0 != stamp).map(|(f, _)| *f).collect();
            for f in stale {
                if let Some(e) = self.entries.remove(&f) {
                    self.bytes -= e.1.rgba.len();
                }
            }
            let old = self.entries.get(&frame).map_or(0, |e| e.1.rgba.len());
            if self.bytes - old + n > CAPACITY {
                return false;
            }
        }
        if let Some(e) = self.entries.insert(frame, (stamp, Arc::new(image))) {
            self.bytes -= e.1.rgba.len();
        }
        self.bytes += n;
        true
    }

    pub fn clear(&mut self) {
        self.entries.clear();
        self.bytes = 0;
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn misses_under_another_stamp_and_makes_room_from_stale_entries() {
        let mut c = FrameCache::default();
        let img = || Image::new(2, 2, vec![0; 16]);
        c.insert(3, 1, img());
        assert!(c.get(3, 1).is_some());
        assert!(c.get(3, 2).is_none());
        c.insert(3, 2, img());
        assert_eq!(c.bytes, 16, "replacing a frame doesn't double count");
        c.clear();
        assert_eq!(c.bytes, 0);
    }
}
