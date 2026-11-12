//! Media Foundation's source reader: decode to RGB32 with its video
//! processor, seek by 100-ns units, find frames by their timestamps.

use std::path::Path;

use anyhow::{bail, Context, Result};
use windows::core::{GUID, HSTRING};
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
            // Let the reader convert YUV to RGB32 for us.
            attrs.SetUINT32(&MF_SOURCE_READER_ENABLE_VIDEO_PROCESSING, 1)?;
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
        if self.next != Some(index) {
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

    /// RGB32 (B, G, R, X rows; a negative stride means bottom-up) to upright RGBA8.
    fn pixels(&self, sample: &IMFSample, index: usize) -> Result<Frame> {
        let (w, h, stride) = self.stored;
        let mut rgba = Vec::with_capacity((w * h * 4) as usize);
        unsafe {
            let buffer = sample.ConvertToContiguousBuffer()?;
            let mut data: *mut u8 = std::ptr::null_mut();
            let mut len = 0u32;
            buffer.Lock(&mut data, None, Some(&mut len))?;
            let row_bytes = stride.unsigned_abs() as usize;
            if (len as usize) < row_bytes * h as usize || row_bytes < w as usize * 4 {
                buffer.Unlock()?;
                bail!("short video frame ({len} bytes for {w} × {h})");
            }
            let bytes = std::slice::from_raw_parts(data, len as usize);
            for y in 0..h as usize {
                let row = if stride < 0 { h as usize - 1 - y } else { y };
                for px in bytes[row * row_bytes..row * row_bytes + w as usize * 4].chunks_exact(4) {
                    rgba.extend_from_slice(&[px[2], px[1], px[0], 255]);
                }
            }
            buffer.Unlock()?;
        }
        let (width, height, rgba) = if self.info.rotation == 0 { (w, h, rgba) } else { rotate(w, h, &rgba, self.info.rotation) };
        Ok(Frame { index, width, height, rgba })
    }
}
