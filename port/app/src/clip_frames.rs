//! A clip's earlier frames for the Digital video stage's re-runs (the Mac's
//! DigitalClipFrames): a reader of its own, so the one showing the current
//! frame keeps its place, and the crop the chain sees.

use std::path::Path;

use anyhow::Result;
use ntscrt_engine::crop::Crop;
use ntscrt_engine::Image;
use ntscrt_media::VideoReader;

pub struct ClipFrames {
    reader: VideoReader,
    crop: Option<Crop>,
}

impl ClipFrames {
    pub fn open(path: &Path, crop: Option<Crop>) -> Result<Self> {
        Ok(Self { reader: VideoReader::open(path)?, crop })
    }

    /// Frame `n` (cropped) to `body` as RGBA8 (pixels, width, height, row
    /// bytes); false when it can't be read.
    pub fn visit(&mut self, n: i64, body: &mut dyn FnMut(&[u8], usize, usize, usize)) -> bool {
        let Ok(index) = usize::try_from(n) else { return false };
        let Ok(f) = self.reader.frame(index) else { return false };
        let pic = Image::new(f.width, f.height, f.rgba);
        let pic = match self.crop {
            Some(c) => c.apply(&pic),
            None => pic,
        };
        body(&pic.rgba, pic.width as usize, pic.height as usize, pic.width as usize * 4);
        true
    }
}

/// Run `f` with the clip's frames as the Digital stage's visitor (None
/// for a still: its picture never changes).
pub fn with_visitor<R>(clip: &mut Option<ClipFrames>, f: impl FnOnce(Option<&mut ntscrt_engine::FrameVisitor<'_>>) -> R) -> R {
    match clip {
        Some(c) => {
            let mut v = |n: i64, body: &mut dyn FnMut(&[u8], usize, usize, usize)| c.visit(n, body);
            f(Some(&mut v))
        }
        None => f(None),
    }
}
