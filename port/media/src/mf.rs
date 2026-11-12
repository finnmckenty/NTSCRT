//! Media Foundation's source reader: decode to RGB32 with its video
//! processor, seek by 100-ns units, find frames by their timestamps.

use std::path::Path;

use anyhow::{bail, Context, Result};
use windows::core::{Interface, GUID, HSTRING};
use windows::Win32::Media::MediaFoundation::*;
use windows::Win32::System::Com::StructuredStorage::PROPVARIANT;
use windows::Win32::System::Com::{CoInitializeEx, COINIT_MULTITHREADED};
use windows::Win32::System::Variant::VT_I8;

use crate::{rotate, Frame, VideoInfo};

const STREAM: u32 = MF_SOURCE_READER_FIRST_VIDEO_STREAM.0 as u32;
const HNS: f64 = 10_000_000.0;

pub struct Reader {
    reader: IMFSourceReader,
    info: VideoInfo,
    /// Stored (pre-rotation) frame size and row stride.
    stored: (u32, u32, i32),
    /// The frame the next read returns, when reading straight on.
    next: Option<usize>,
    /// The last frame decoded, for the end of the clip.
    last: Option<Frame>,
    /// The first frame's timestamp (100 ns). MP4s with B-frames usually
    /// start a frame or two in (an edit list Media Foundation doesn't apply
    /// and AVFoundation does), so timestamps count from here.
    start: i64,
}

pub(crate) fn startup() -> Result<()> {
    // Both are reference counted; once per thread that opens a clip is fine.
    unsafe {
        let _ = CoInitializeEx(None, COINIT_MULTITHREADED);
        MFStartup(MF_VERSION, MFSTARTUP_FULL).context("Media Foundation didn't start")?;
    }
    Ok(())
}

fn split(v: u64) -> (u32, u32) {
    ((v >> 32) as u32, v as u32)
}

impl Reader {
    pub fn open(path: &Path) -> Result<Self> {
        startup()?;
        unsafe {
            let mut attrs: Option<IMFAttributes> = None;
            MFCreateAttributes(&mut attrs, 2)?;
            let attrs = attrs.context("attributes")?;
            // Let the reader convert YUV to RGB32 for us. The advanced video
            // processor, not the basic one: the basic one misreads the
            // decoder's padded rows when the width isn't a multiple of 16
            // (a 1112 px clip came out sheared), and the advanced one's
            // chroma is closer to the Mac's AVFoundation decode anyway.
            attrs.SetUINT32(&MF_SOURCE_READER_ENABLE_ADVANCED_VIDEO_PROCESSING, 1)?;
            let url = HSTRING::from(path.as_os_str());
            let reader = MFCreateSourceReaderFromURL(&url, &attrs).with_context(|| format!("couldn't open {}", path.display()))?;
            reader.SetStreamSelection(MF_SOURCE_READER_ALL_STREAMS.0 as u32, false)?;
            reader.SetStreamSelection(STREAM, true).context("no video track")?;

            let native = reader.GetNativeMediaType(STREAM, 0)?;
            let (num, den) = split(native.GetUINT64(&MF_MT_FRAME_RATE).unwrap_or(30u64 << 32 | 1));
            let fps = if num > 0 && den > 0 { num as f64 / den as f64 } else { 30.0 };
            let rotation = native.GetUINT32(&MF_MT_VIDEO_ROTATION).unwrap_or(0) % 360;

            let rgb = MFCreateMediaType()?;
            rgb.SetGUID(&MF_MT_MAJOR_TYPE, &MFMediaType_Video)?;
            rgb.SetGUID(&MF_MT_SUBTYPE, &MFVideoFormat_RGB32)?;
            reader.SetCurrentMediaType(STREAM, None, &rgb).context("can't decode this video to RGB")?;
            let current = reader.GetCurrentMediaType(STREAM)?;
            let (w, h) = split(current.GetUINT64(&MF_MT_FRAME_SIZE)?);
            let stride = current.GetUINT32(&MF_MT_DEFAULT_STRIDE).map(|s| s as i32).unwrap_or(w as i32 * 4);

            let duration = reader
                .GetPresentationAttribute(MF_SOURCE_READER_MEDIASOURCE.0 as u32, &MF_PD_DURATION)
                .map(|v| v.Anonymous.Anonymous.Anonymous.uhVal as f64 / HNS)
                .unwrap_or(0.0);
            let (uw, uh) = if rotation % 180 == 90 { (h, w) } else { (w, h) };
            let fps_rational = if num > 0 && den > 0 { (num, den) } else { (30, 1) };
            let info = VideoInfo { width: uw, height: uh, fps, fps_rational, total_frames: VideoInfo::frames_for(duration, fps), duration, rotation };
            let mut r = Self { reader, info, stored: (w, h, stride), next: Some(0), last: None, start: 0 };
            // Time zero is the first frame's timestamp; keep that frame as 0.
            let (stamp, sample) = r.read()?.context("the clip has no frames")?;
            r.start = stamp;
            let first = r.pixels(&sample, 0)?;
            r.last = Some(first);
            r.next = Some(1);
            Ok(r)
        }
    }

    pub fn info(&self) -> VideoInfo {
        self.info
    }

    /// The next decoded sample and its timestamp; None at the end.
    fn read(&mut self) -> Result<Option<(i64, IMFSample)>> {
        loop {
            let mut flags = 0u32;
            let mut stamp = 0i64;
            let mut sample: Option<IMFSample> = None;
            unsafe {
                self.reader.ReadSample(STREAM, 0, None, Some(&mut flags), Some(&mut stamp), Some(&mut sample)).context("decode")?;
            }
            if flags & MF_SOURCE_READERF_ENDOFSTREAM.0 as u32 != 0 {
                return Ok(None);
            }
            if let Some(sample) = sample {
                return Ok(Some((stamp, sample)));
            }
        }
    }

    fn seek(&mut self, index: usize) -> Result<()> {
        // A frame early, and inside the clip: Media Foundation's duration
        // doesn't include the start offset, and seeking past it fails. The
        // reader lands on the keyframe before anyway and decodes forward.
        let frame = HNS / self.info.timescale();
        let end = (self.info.duration * HNS - frame).max(0.0) as i64;
        let t = (self.start + ((index as f64 - 1.0) * frame) as i64).clamp(0, end);
        let mut pos = PROPVARIANT::default();
        unsafe {
            (*pos.Anonymous.Anonymous).vt = VT_I8;
            (*pos.Anonymous.Anonymous).Anonymous.hVal = t;
            self.reader.SetCurrentPosition(&GUID::zeroed(), &pos).context("seek")?;
        }
        self.next = None;
        Ok(())
    }

    pub fn frame(&mut self, index: usize) -> Result<Frame> {
        if let Some(last) = &self.last {
            if last.index == index {
                return Ok(last.clone());
            }
        }
        // A short way ahead, decoding on is cheaper than seeking back to a
        // keyframe and decoding forward from there.
        let ahead = self.next.is_some_and(|n| n <= index && index - n <= 12);
        if !ahead {
            self.seek(index)?;
        }
        // Decode on until the frame at or past `index` (after a seek the
        // reader starts at the keyframe before it).
        loop {
            let Some((stamp, sample)) = self.read()? else {
                self.next = None;
                return self.last.clone().context("the clip has no frames");
            };
            let at = self.info.frame_at((stamp - self.start) as f64 / HNS);
            if at < index {
                continue;
            }
            let frame = self.pixels(&sample, at)?;
            self.next = Some(at + 1);
            self.last = Some(frame.clone());
            return Ok(frame);
        }
    }

    /// RGB32 (B, G, R, X rows) to upright RGBA8. The video processor often
    /// pads the picture to whole 16-pixel blocks (a 1112 × 834 clip comes out
    /// 1120 × 848) while the media type still gives the clip's size and
    /// stride: take the real pitch from the buffer.
    fn pixels(&self, sample: &IMFSample, index: usize) -> Result<Frame> {
        let (w, h, stride) = self.stored;
        let (wu, hu) = (w as usize, h as usize);
        let mut rgba = Vec::with_capacity(wu * hu * 4);
        let mut put = |row: &[u8]| {
            for px in row[..wu * 4].chunks_exact(4) {
                rgba.extend_from_slice(&[px[2], px[1], px[0], 255]);
            }
        };
        unsafe {
            // One buffer with a 2D interface: its scan line 0 is the top row.
            let two_d = if sample.GetBufferCount()? == 1 {
                sample.GetBufferByIndex(0)?.cast::<IMF2DBuffer>().ok()
            } else {
                None
            };
            if let Some(buffer) = two_d {
                let mut top: *mut u8 = std::ptr::null_mut();
                let mut pitch = 0i32;
                buffer.Lock2D(&mut top, &mut pitch)?;
                if top.is_null() || (pitch.unsigned_abs() as usize) < wu * 4 {
                    buffer.Unlock2D()?;
                    bail!("bad video frame pitch ({pitch} for {w} px)");
                }
                for y in 0..hu {
                    let row = top.offset(y as isize * pitch as isize);
                    put(std::slice::from_raw_parts(row, wu * 4));
                }
                buffer.Unlock2D()?;
            } else {
                let buffer = sample.ConvertToContiguousBuffer()?;
                let mut data: *mut u8 = std::ptr::null_mut();
                let mut len = 0u32;
                buffer.Lock(&mut data, None, Some(&mut len))?;
                let len = len as usize;
                let row_bytes = padded_pitch(len, wu, hu).unwrap_or(stride.unsigned_abs() as usize);
                if len < row_bytes * hu || row_bytes < wu * 4 {
                    buffer.Unlock()?;
                    bail!("short video frame ({len} bytes for {w} × {h})");
                }
                let bytes = std::slice::from_raw_parts(data, len);
                for y in 0..hu {
                    let row = if stride < 0 { hu - 1 - y } else { y };
                    put(&bytes[row * row_bytes..(row + 1) * row_bytes]);
                }
                buffer.Unlock()?;
            }
        }
        let (width, height, rgba) = if self.info.rotation == 0 { (w, h, rgba) } else { rotate(w, h, &rgba, self.info.rotation) };
        Ok(Frame { index, width, height, rgba })
    }
}

/// The row pitch of a `w` × `h` RGB32 picture in a `len`-byte buffer whose
/// width and height may both be padded to a block size: the exact size
/// first, then 16-pixel blocks (H.264's macroblocks) and the other common
/// alignments. None when no padding explains the length.
fn padded_pitch(len: usize, w: usize, h: usize) -> Option<usize> {
    if len == w * h * 4 {
        return Some(w * 4);
    }
    [16, 32, 64, 128, 2, 4, 8].into_iter().map(|a| w.div_ceil(a) * a * 4).find(|&pitch| {
        len % pitch == 0 && (h..h + 128).contains(&(len / pitch))
    })
}

#[cfg(test)]
mod tests {
    use super::padded_pitch;

    #[test]
    fn pitch_of_padded_frames() {
        assert_eq!(padded_pitch(1112 * 834 * 4, 1112, 834), Some(1112 * 4));
        // The clip that came out sheared: 1112 × 834 decoded as 1120 × 848.
        assert_eq!(padded_pitch(3_799_040, 1112, 834), Some(1120 * 4));
        // 1080p: only the height is padded.
        assert_eq!(padded_pitch(1920 * 1088 * 4, 1920, 1080), Some(1920 * 4));
        assert_eq!(padded_pitch(1000 * 4, 1112, 834), None);
    }
}
