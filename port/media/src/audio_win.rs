//! A clip's sound on Windows (see audio.rs): its first audio track decoded
//! to 16-bit PCM by Media Foundation's source reader — the track and the
//! decode the MP4 writer uses — and written to the default output device
//! through WASAPI in shared mode, in the file's own format (Windows
//! converts the rate and channels: AUDCLNT_STREAMFLAGS_AUTOCONVERTPCM).
//!
//! Two threads per open clip, both ended by `Shared::quit` (the window
//! dropping its `VideoAudio`): one decodes the whole track into memory,
//! one writes the device a little ahead of what is being heard.

use std::path::PathBuf;
use std::sync::{Arc, Mutex};
use std::time::Duration;

use windows::Win32::Media::Audio::{
    eConsole, eRender, IAudioClient, IAudioRenderClient, IMMDeviceEnumerator, MMDeviceEnumerator, AUDCLNT_SHAREMODE_SHARED,
    AUDCLNT_STREAMFLAGS_AUTOCONVERTPCM, AUDCLNT_STREAMFLAGS_SRC_DEFAULT_QUALITY, WAVEFORMATEX, WAVE_FORMAT_PCM,
};
use windows::Win32::Media::MediaFoundation::*;
use windows::Win32::System::Com::{CoCreateInstance, CoInitializeEx, CLSCTX_ALL, COINIT_MULTITHREADED};

use crate::audio::{downmix, Line, Pcm, Shared, Step, LONGEST};

const AUDIO: u32 = MF_SOURCE_READER_FIRST_AUDIO_STREAM.0 as u32;
const HNS: f64 = 10_000_000.0;
/// How far ahead of what is being heard the device is kept written
/// (seconds): room for this thread to be late, and how long a stop takes
/// at most.
const AHEAD: f64 = 0.08;

/// Open the clip's sound and play it as `shared.command` says, until
/// `shared.quit`.
pub(crate) fn start(path: PathBuf, shared: Arc<Shared>) {
    std::thread::spawn(move || {
        if let Err(e) = decode(&path, &shared) {
            // No sound track, or none Media Foundation can decode: the clip
            // plays without.
            if std::env::var_os("NTSCRT_PROFILE").is_some() {
                eprintln!("[audio] none: {e:#}");
            }
            shared.set_none();
        }
    });
}

/// Decode the first audio track into memory, starting the output thread
/// once its format is known.
fn decode(path: &std::path::Path, shared: &Arc<Shared>) -> anyhow::Result<()> {
    use anyhow::Context;
    crate::mf::startup()?;
    unsafe {
        let (reader, pcm_type, duration) = crate::mf_writer::pcm_reader(path)?.context("no sound track")?;
        let rate = pcm_type.GetUINT32(&MF_MT_AUDIO_SAMPLES_PER_SECOND)?;
        let channels = pcm_type.GetUINT32(&MF_MT_AUDIO_NUM_CHANNELS)? as usize;
        let bits = pcm_type.GetUINT32(&MF_MT_AUDIO_BITS_PER_SAMPLE).unwrap_or(16);
        anyhow::ensure!(bits == 16 && rate > 0 && (1..=8).contains(&channels), "sound format not handled ({bits} bits, {rate} Hz, {channels} channels)");
        // Kept as mono or stereo (audio::downmix).
        let kept = channels.min(2);
        let seconds = (duration as f64 / HNS).min(LONGEST);
        let limit = (LONGEST * rate as f64) as usize * kept;
        // Room for the whole track up front, so appending never moves the
        // samples while the output thread waits for them.
        let room = if seconds > 0.0 { ((seconds + 1.0) * rate as f64) as usize * kept } else { 0 };
        let pcm = Arc::new(Pcm { rate, channels: kept as u16, samples: Mutex::new(Vec::with_capacity(room.min(limit))) });
        shared.set_ready();
        {
            let (pcm, shared) = (pcm.clone(), shared.clone());
            std::thread::spawn(move || output(&pcm, &shared));
        }
        let mut chunk: Vec<i16> = Vec::new();
        let mut total = 0usize;
        while !shared.quitting() && total < limit {
            let mut flags = 0u32;
            let mut stamp = 0i64;
            let mut sample: Option<IMFSample> = None;
            reader.ReadSample(AUDIO, 0, None, Some(&mut flags), Some(&mut stamp), Some(&mut sample)).context("decode sound")?;
            if flags & MF_SOURCE_READERF_ENDOFSTREAM.0 as u32 != 0 {
                break;
            }
            let Some(sample) = sample else { continue };
            let buffer = sample.ConvertToContiguousBuffer()?;
            let mut data: *mut u8 = std::ptr::null_mut();
            let mut len = 0u32;
            buffer.Lock(&mut data, None, Some(&mut len))?;
            let bytes = std::slice::from_raw_parts(data, len as usize);
            chunk.clear();
            chunk.extend(bytes.chunks_exact(2).map(|b| i16::from_le_bytes([b[0], b[1]])));
            buffer.Unlock()?;
            let n = downmix(&mut chunk, channels).min(limit - total);
            // (Whole frames only.)
            let n = n - n % kept;
            if let Ok(mut all) = pcm.samples.lock() {
                all.extend_from_slice(&chunk[..n]);
            }
            total += n;
        }
        if std::env::var_os("NTSCRT_PROFILE").is_some() {
            eprintln!("[audio] decoded {:.2} s ({rate} Hz, {channels} channels)", total as f64 / (rate as f64 * kept as f64));
        }
    }
    Ok(())
}

/// The default output device, taking the clip's PCM as it is.
struct Device {
    client: IAudioClient,
    render: IAudioRenderClient,
    /// The device buffer's size, frames.
    size: u32,
    /// Seconds from a sample leaving the buffer to its being heard, as far
    /// as the device says.
    latency: f64,
}

unsafe fn open_device(rate: u32, channels: u16) -> windows::core::Result<Device> {
    let enumerator: IMMDeviceEnumerator = CoCreateInstance(&MMDeviceEnumerator, None, CLSCTX_ALL)?;
    let device = enumerator.GetDefaultAudioEndpoint(eRender, eConsole)?;
    let client: IAudioClient = device.Activate(CLSCTX_ALL, None)?;
    let block = channels * 2;
    let format = WAVEFORMATEX {
        wFormatTag: WAVE_FORMAT_PCM as u16,
        nChannels: channels,
        nSamplesPerSec: rate,
        nAvgBytesPerSec: rate * block as u32,
        nBlockAlign: block,
        wBitsPerSample: 16,
        cbSize: 0,
    };
    // A fifth of a second of buffer; only AHEAD of it is kept filled.
    client.Initialize(AUDCLNT_SHAREMODE_SHARED, AUDCLNT_STREAMFLAGS_AUTOCONVERTPCM | AUDCLNT_STREAMFLAGS_SRC_DEFAULT_QUALITY, 2_000_000, 0, &format, None)?;
    let size = client.GetBufferSize()?;
    let latency = client.GetStreamLatency().unwrap_or(0) as f64 / HNS;
    let render: IAudioRenderClient = client.GetService()?;
    Ok(Device { client, render, size, latency })
}

/// Write `frames` frames from where the line is.
unsafe fn write(dev: &Device, line: &mut Line, pcm: &Pcm, mute: bool, frames: u32) -> windows::core::Result<()> {
    if frames == 0 {
        return Ok(());
    }
    let channels = pcm.channels as usize;
    let data = dev.render.GetBuffer(frames)?;
    let out = std::slice::from_raw_parts_mut(data as *mut i16, frames as usize * channels);
    match pcm.samples.lock() {
        Ok(all) => line.fill(&all, channels, mute, out),
        Err(_) => line.fill(&[], channels, true, out),
    }
    dev.render.ReleaseBuffer(frames, 0)
}

/// One turn with the device. Ok(false): nothing is playing.
unsafe fn turn(dev: &Device, line: &mut Line, pcm: &Pcm, shared: &Shared) -> windows::core::Result<bool> {
    let ahead = ((AHEAD * pcm.rate as f64) as u32).min(dev.size);
    let Ok(cmd) = shared.command.lock().map(|c| *c) else { return Ok(false) };
    let queued = dev.client.GetCurrentPadding()?;
    let clock = shared.clock();
    match line.step(&cmd, clock, queued, dev.latency) {
        Step::Idle { stop } => {
            if stop {
                dev.client.Stop()?;
                dev.client.Reset()?;
            }
            if let Ok(mut h) = shared.heard.lock() {
                *h = None;
            }
            Ok(false)
        }
        Step::Start => {
            // (Stopping a stopped stream is fine: S_FALSE.)
            dev.client.Stop()?;
            dev.client.Reset()?;
            write(dev, line, pcm, shared.mute, ahead)?;
            dev.client.Start()?;
            if let Ok(mut h) = shared.heard.lock() {
                *h = Some((clock, line.heard(ahead, dev.latency)));
            }
            Ok(true)
        }
        Step::Continue => {
            let frames = ahead.saturating_sub(queued).min(dev.size.saturating_sub(queued));
            write(dev, line, pcm, shared.mute, frames)?;
            if let Ok(mut h) = shared.heard.lock() {
                *h = Some((clock, line.heard(queued + frames, dev.latency)));
            }
            Ok(true)
        }
    }
}

/// The output thread: keep the device written along the line the window
/// gives. Without a device (none plugged in, or the one in use went away:
/// AUDCLNT_E_DEVICE_INVALIDATED and the like) the clip plays silent, and
/// the default device is tried again every second.
fn output(pcm: &Pcm, shared: &Shared) {
    unsafe {
        let _ = CoInitializeEx(None, COINIT_MULTITHREADED);
    }
    let mut line = Line::new(pcm.rate);
    let mut device: Option<Device> = None;
    let mut retry_at = 0.0;
    let profile = std::env::var_os("NTSCRT_PROFILE").is_some();
    while !shared.quitting() {
        if device.is_none() && shared.clock() >= retry_at {
            match unsafe { open_device(pcm.rate, pcm.channels) } {
                Ok(d) => {
                    if profile {
                        eprintln!("[audio] output device open: {} frame buffer, latency {:.1} ms", d.size, d.latency * 1000.0);
                    }
                    device = Some(d);
                }
                Err(e) => {
                    if profile && retry_at == 0.0 {
                        eprintln!("[audio] no output device: {e}");
                    }
                    retry_at = shared.clock() + 1.0;
                }
            }
        }
        let mut playing = false;
        if let Some(dev) = &device {
            match unsafe { turn(dev, &mut line, pcm, shared) } {
                Ok(p) => playing = p,
                Err(e) => {
                    if profile {
                        eprintln!("[audio] output device lost: {e}");
                    }
                    device = None;
                    line.lost();
                    retry_at = shared.clock() + 1.0;
                    if let Ok(mut h) = shared.heard.lock() {
                        *h = None;
                    }
                }
            }
        }
        std::thread::sleep(Duration::from_millis(if playing { 5 } else { 15 }));
    }
    if let Some(dev) = &device {
        unsafe {
            let _ = dev.client.Stop();
        }
    }
}
