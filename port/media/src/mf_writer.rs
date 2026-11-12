//! Media Foundation's sink writer: RGB32 frames into H.264 or HEVC in an
//! MP4, with the source clip's audio decoded to PCM and re-encoded as AAC,
//! interleaved as the video goes (audio up to each frame's time).

use std::path::Path;

use anyhow::{bail, Context, Result};
use windows::core::{GUID, HSTRING};
use windows::Win32::Media::MediaFoundation::*;
use windows::Win32::System::Com::StructuredStorage::PROPVARIANT;
use windows::Win32::System::Variant::VT_I8;

use crate::mf::startup;
use crate::Codec;

const HNS: f64 = 10_000_000.0;
const AUDIO: u32 = MF_SOURCE_READER_FIRST_AUDIO_STREAM.0 as u32;

/// The source clip's sound, decoded to PCM, replayed `loops` times.
struct Audio {
    reader: IMFSourceReader,
    stream: u32,
    /// The clip's length (100 ns): each loop's sound starts that much later.
    clip: i64,
    pass: usize,
    loops: usize,
    /// The first sample's timestamp, so the sound starts at zero.
    start: Option<i64>,
    done: bool,
}

pub struct Writer {
    sink: IMFSinkWriter,
    video: u32,
    size: (u32, u32),
    fps: (u32, u32),
    frame: u64,
    audio: Option<Audio>,
}

unsafe fn pcm_reader(path: &Path) -> Result<Option<(IMFSourceReader, IMFMediaType, i64)>> {
    let reader = MFCreateSourceReaderFromURL(&HSTRING::from(path.as_os_str()), None)?;
    reader.SetStreamSelection(MF_SOURCE_READER_ALL_STREAMS.0 as u32, false)?;
    if reader.SetStreamSelection(AUDIO, true).is_err() {
        return Ok(None); // no sound
    }
    let pcm = MFCreateMediaType()?;
    pcm.SetGUID(&MF_MT_MAJOR_TYPE, &MFMediaType_Audio)?;
    pcm.SetGUID(&MF_MT_SUBTYPE, &MFAudioFormat_PCM)?;
    pcm.SetUINT32(&MF_MT_AUDIO_BITS_PER_SAMPLE, 16)?;
    if reader.SetCurrentMediaType(AUDIO, None, &pcm).is_err() {
        return Ok(None);
    }
    let current = reader.GetCurrentMediaType(AUDIO)?;
    let duration = reader
        .GetPresentationAttribute(MF_SOURCE_READER_MEDIASOURCE.0 as u32, &MF_PD_DURATION)
        .map(|v| v.Anonymous.Anonymous.Anonymous.uhVal as i64)
        .unwrap_or(0);
    Ok(Some((reader, current, duration)))
}

impl Writer {
    pub fn create(
        path: &Path,
        size: (u32, u32),
        fps: (u32, u32),
        codec: Codec,
        bitrate: u32,
        audio_from: Option<&Path>,
        loops: usize,
    ) -> Result<Self> {
        startup()?;
        let (w, h) = size;
        if w % 2 != 0 || h % 2 != 0 {
            bail!("video sizes must be even ({w} × {h})");
        }
        unsafe {
            let mut attrs: Option<IMFAttributes> = None;
            MFCreateAttributes(&mut attrs, 3)?;
            let attrs = attrs.context("attributes")?;
            attrs.SetUINT32(&MF_READWRITE_ENABLE_HARDWARE_TRANSFORMS, 1)?;
            attrs.SetGUID(&MF_TRANSCODE_CONTAINERTYPE, &MFTranscodeContainerType_MPEG4)?;
            let _ = std::fs::remove_file(path);
            let sink = MFCreateSinkWriterFromURL(&HSTRING::from(path.as_os_str()), None, &attrs)
                .with_context(|| format!("couldn't write {}", path.display()))?;

            let frame_size = (w as u64) << 32 | h as u64;
            let rate = (fps.0 as u64) << 32 | fps.1 as u64;
            let out = MFCreateMediaType()?;
            out.SetGUID(&MF_MT_MAJOR_TYPE, &MFMediaType_Video)?;
            out.SetGUID(&MF_MT_SUBTYPE, if codec == Codec::Hevc { &MFVideoFormat_HEVC } else { &MFVideoFormat_H264 })?;
            out.SetUINT32(&MF_MT_AVG_BITRATE, bitrate)?;
            out.SetUINT32(&MF_MT_INTERLACE_MODE, MFVideoInterlace_Progressive.0 as u32)?;
            out.SetUINT64(&MF_MT_FRAME_SIZE, frame_size)?;
            out.SetUINT64(&MF_MT_FRAME_RATE, rate)?;
            out.SetUINT64(&MF_MT_PIXEL_ASPECT_RATIO, 1u64 << 32 | 1)?;
            let video = sink.AddStream(&out).context(if codec == Codec::Hevc {
                "no HEVC encoder on this PC (Windows needs the HEVC Video Extensions)"
            } else {
                "no H.264 encoder"
            })?;
            let input = MFCreateMediaType()?;
            input.SetGUID(&MF_MT_MAJOR_TYPE, &MFMediaType_Video)?;
            input.SetGUID(&MF_MT_SUBTYPE, &MFVideoFormat_RGB32)?;
            input.SetUINT32(&MF_MT_INTERLACE_MODE, MFVideoInterlace_Progressive.0 as u32)?;
            input.SetUINT64(&MF_MT_FRAME_SIZE, frame_size)?;
            input.SetUINT64(&MF_MT_FRAME_RATE, rate)?;
            input.SetUINT64(&MF_MT_PIXEL_ASPECT_RATIO, 1u64 << 32 | 1)?;
            // Positive stride: rows top to bottom.
            input.SetUINT32(&MF_MT_DEFAULT_STRIDE, w * 4)?;
            sink.SetInputMediaType(video, &input, None).context("the encoder won't take RGB frames")?;

            let mut audio = None;
            if let Some(src) = audio_from {
                if let Some((reader, pcm, clip)) = pcm_reader(src)? {
                    let rate = pcm.GetUINT32(&MF_MT_AUDIO_SAMPLES_PER_SECOND)?;
                    let channels = pcm.GetUINT32(&MF_MT_AUDIO_NUM_CHANNELS)?;
                    // The AAC encoder takes 44.1 or 48 kHz, mono or stereo (or 5.1).
                    if matches!(rate, 44100 | 48000) && matches!(channels, 1 | 2 | 6) {
                        let aac = MFCreateMediaType()?;
                        aac.SetGUID(&MF_MT_MAJOR_TYPE, &MFMediaType_Audio)?;
                        aac.SetGUID(&MF_MT_SUBTYPE, &MFAudioFormat_AAC)?;
                        aac.SetUINT32(&MF_MT_AUDIO_BITS_PER_SAMPLE, 16)?;
                        aac.SetUINT32(&MF_MT_AUDIO_SAMPLES_PER_SECOND, rate)?;
                        aac.SetUINT32(&MF_MT_AUDIO_NUM_CHANNELS, channels)?;
                        aac.SetUINT32(&MF_MT_AUDIO_AVG_BYTES_PER_SECOND, 24000)?; // 192 kb/s
                        let stream = sink.AddStream(&aac).context("no AAC encoder")?;
                        sink.SetInputMediaType(stream, &pcm, None).context("the AAC encoder won't take this sound")?;
                        audio = Some(Audio { reader, stream, clip, pass: 0, loops: loops.max(1), start: None, done: false });
                    }
                }
            }
            sink.BeginWriting().context("couldn't start writing")?;
            Ok(Self { sink, video, size, fps, frame: 0, audio })
        }
    }

    fn time(&self, frame: u64) -> i64 {
        (frame as f64 * HNS * self.fps.1 as f64 / self.fps.0 as f64).round() as i64
    }

    pub fn write(&mut self, rgba: &[u8]) -> Result<()> {
        let (w, h) = self.size;
        let len = (w * h * 4) as usize;
        if rgba.len() != len {
            bail!("frame is {} bytes, expected {len}", rgba.len());
        }
        let (t0, t1) = (self.time(self.frame), self.time(self.frame + 1));
        unsafe {
            let buffer = MFCreateMemoryBuffer(len as u32)?;
            let mut data: *mut u8 = std::ptr::null_mut();
            buffer.Lock(&mut data, None, None)?;
            let dst = std::slice::from_raw_parts_mut(data, len);
            for (d, s) in dst.chunks_exact_mut(4).zip(rgba.chunks_exact(4)) {
                d.copy_from_slice(&[s[2], s[1], s[0], 255]);
            }
            buffer.Unlock()?;
            buffer.SetCurrentLength(len as u32)?;
            let sample = MFCreateSample()?;
            sample.AddBuffer(&buffer)?;
            sample.SetSampleTime(t0)?;
            sample.SetSampleDuration(t1 - t0)?;
            self.sink.WriteSample(self.video, &sample).context("encode")?;
        }
        self.frame += 1;
        self.pump_audio(t1)
    }

    /// Write the sound up to `until` (100 ns), looping the clip's sound.
    fn pump_audio(&mut self, until: i64) -> Result<()> {
        let Some(a) = self.audio.as_mut() else { return Ok(()) };
        while !a.done {
            let mut flags = 0u32;
            let mut stamp = 0i64;
            let mut sample: Option<IMFSample> = None;
            unsafe {
                a.reader.ReadSample(AUDIO, 0, None, Some(&mut flags), Some(&mut stamp), Some(&mut sample))?;
            }
            if flags & MF_SOURCE_READERF_ENDOFSTREAM.0 as u32 != 0 {
                a.pass += 1;
                if a.pass >= a.loops {
                    a.done = true;
                    break;
                }
                // Again from the top, a clip's length later.
                let mut pos = PROPVARIANT::default();
                unsafe {
                    (*pos.Anonymous.Anonymous).vt = VT_I8;
                    (*pos.Anonymous.Anonymous).Anonymous.hVal = 0;
                    a.reader.SetCurrentPosition(&GUID::zeroed(), &pos)?;
                }
                continue;
            }
            let Some(sample) = sample else { continue };
            let start = *a.start.get_or_insert(stamp);
            let at = stamp - start + a.pass as i64 * a.clip;
            unsafe {
                sample.SetSampleTime(at)?;
                self.sink.WriteSample(a.stream, &sample).context("encode sound")?;
            }
            if at >= until {
                break;
            }
        }
        Ok(())
    }

    pub fn finish(mut self) -> Result<()> {
        // The rest of the sound, then close the file.
        self.pump_audio(i64::MAX)?;
        unsafe { self.sink.Finalize().context("couldn't finish the file") }
    }
}
