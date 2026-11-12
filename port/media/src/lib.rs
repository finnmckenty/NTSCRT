//! Video in for NTSCRT on Windows: Media Foundation's source reader, frames
//! as RGBA8. Frames are numbered the Mac's way (`VideoSource.swift`): the
//! clip has round(duration × fps) frames, and frame n is the one showing at
//! n ÷ round(fps) seconds.

use anyhow::Result;

#[derive(Clone, Copy, Debug, PartialEq)]
pub struct VideoInfo {
    /// Upright size (after the clip's rotation, as the Mac shows it).
    pub width: u32,
    pub height: u32,
    pub fps: f64,
    /// The frame rate as stored (numerator, denominator), for writing.
    pub fps_rational: (u32, u32),
    pub total_frames: usize,
    pub duration: f64,
    /// Clockwise degrees applied to stored frames to show them upright.
    pub rotation: u32,
}

impl VideoInfo {
    /// The Mac's frame count: max(1, round(duration × fps)).
    pub fn frames_for(duration: f64, fps: f64) -> usize {
        ((duration * fps).round() as usize).max(1)
    }
    /// The timescale frames are placed on: round(fps), as the Mac's CMTime.
    pub fn timescale(&self) -> f64 {
        self.fps.round().max(1.0)
    }
    /// The frame a timestamp (seconds) belongs to.
    pub fn frame_at(&self, seconds: f64) -> usize {
        (seconds * self.timescale()).round().max(0.0) as usize
    }
}

/// A decoded frame, RGBA8, rows packed.
#[derive(Clone)]
pub struct Frame {
    pub index: usize,
    pub width: u32,
    pub height: u32,
    pub rgba: Vec<u8>,
}

/// Rotate an RGBA8 picture clockwise by 90, 180 or 270 degrees.
pub fn rotate(w: u32, h: u32, rgba: &[u8], degrees: u32) -> (u32, u32, Vec<u8>) {
    let (w, h) = (w as usize, h as usize);
    let px = |x: usize, y: usize| &rgba[(y * w + x) * 4..(y * w + x) * 4 + 4];
    let (ow, oh) = if degrees % 180 == 90 { (h, w) } else { (w, h) };
    let mut out = Vec::with_capacity(rgba.len());
    for y in 0..oh {
        for x in 0..ow {
            // The source pixel that lands at (x, y).
            let (sx, sy) = match degrees % 360 {
                90 => (y, h - 1 - x),
                180 => (w - 1 - x, h - 1 - y),
                270 => (w - 1 - y, x),
                _ => (x, y),
            };
            out.extend_from_slice(px(sx, sy));
        }
    }
    (ow as u32, oh as u32, out)
}

#[cfg(windows)]
mod mf;
#[cfg(windows)]
mod mf_writer;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Codec {
    H264,
    Hevc,
}

/// An MP4 being written: frames in order, and the source clip's audio
/// (decoded and re-encoded as AAC, once per loop) alongside.
pub struct VideoWriter {
    #[cfg(windows)]
    inner: mf_writer::Writer,
}

impl VideoWriter {
    /// `fps` as (numerator, denominator). `audio_from`: the clip whose
    /// sound to carry, `loops` times over.
    pub fn create(
        path: &std::path::Path,
        size: (u32, u32),
        fps: (u32, u32),
        codec: Codec,
        bitrate: u32,
        audio_from: Option<&std::path::Path>,
        loops: usize,
    ) -> Result<Self> {
        #[cfg(windows)]
        {
            Ok(Self { inner: mf_writer::Writer::create(path, size, fps, codec, bitrate, audio_from, loops)? })
        }
        #[cfg(not(windows))]
        {
            let _ = (path, size, fps, codec, bitrate, audio_from, loops);
            anyhow::bail!("MP4 export needs the Windows build (Media Foundation)")
        }
    }

    /// The next frame, RGBA8 at the writer's size.
    pub fn write(&mut self, rgba: &[u8]) -> Result<()> {
        #[cfg(windows)]
        {
            self.inner.write(rgba)
        }
        #[cfg(not(windows))]
        {
            let _ = rgba;
            anyhow::bail!("MP4 export needs the Windows build")
        }
    }

    pub fn finish(self) -> Result<()> {
        #[cfg(windows)]
        {
            self.inner.finish()
        }
        #[cfg(not(windows))]
        {
            anyhow::bail!("MP4 export needs the Windows build")
        }
    }
}

pub struct VideoReader {
    #[cfg(windows)]
    inner: mf::Reader,
    info: VideoInfo,
}

impl VideoReader {
    pub fn open(path: &std::path::Path) -> Result<Self> {
        #[cfg(windows)]
        {
            let inner = mf::Reader::open(path)?;
            let info = inner.info();
            Ok(Self { inner, info })
        }
        #[cfg(not(windows))]
        {
            let _ = path;
            anyhow::bail!("video needs the Windows build (Media Foundation)")
        }
    }

    pub fn info(&self) -> VideoInfo {
        self.info
    }

    /// Frame `index` (held to the clip). Reading in order continues the
    /// decode; any other frame seeks.
    pub fn frame(&mut self, index: usize) -> Result<Frame> {
        let index = index.min(self.info.total_frames.saturating_sub(1));
        #[cfg(windows)]
        {
            self.inner.frame(index)
        }
        #[cfg(not(windows))]
        {
            let _ = index;
            anyhow::bail!("video needs the Windows build")
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn frame_numbers_follow_the_mac() {
        let info = VideoInfo { width: 1, height: 1, fps: 29.97, fps_rational: (30000, 1001), total_frames: VideoInfo::frames_for(4.004, 29.97), duration: 4.004, rotation: 0 };
        assert_eq!(info.total_frames, 120);
        assert_eq!(info.timescale(), 30.0);
        assert_eq!(info.frame_at(1.0), 30);
        assert_eq!(info.frame_at(0.0333), 1);
    }

    #[test]
    fn rotation_turns_clockwise() {
        // 2 × 1: [A B] → 90° clockwise → a 1 × 2 column [A; B]... top is A.
        let rgba = [1, 0, 0, 255, 2, 0, 0, 255];
        let (w, h, out) = rotate(2, 1, &rgba, 90);
        assert_eq!((w, h), (1, 2));
        assert_eq!((out[0], out[4]), (1, 2));
        let (_, _, out) = rotate(2, 1, &rgba, 180);
        assert_eq!((out[0], out[4]), (2, 1));
        let (w, h, out) = rotate(2, 1, &rgba, 270);
        assert_eq!((w, h, out[0], out[4]), (1, 2, 2, 1));
    }
}
