//! Exports, on a thread of their own with their own engine (the preview keeps
//! running): PNG, MP4 (H.264/HEVC through Media Foundation, with the clip's
//! sound) and GIF. Frame by frame as the Mac's exporters do: a clip's frame
//! n is seeded n + 1; a still becomes a video `seconds` long.

use std::path::PathBuf;
use std::sync::atomic::{AtomicBool, AtomicU32, Ordering};
use std::sync::Arc;

use anyhow::{bail, Context, Result};
use ntscrt_engine::crop::Crop;
use std::collections::HashMap;

use ntscrt_engine::timeline::{Evaluator, Keyframe, ShaderMeta};
use ntscrt_engine::{ntsc_values_json, DownscaleSpec, Engine, Image, NtscSetting, NtscSettings, Settings};
use ntscrt_media::{Codec, VideoReader, VideoWriter};

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Format {
    Png,
    Mp4(Codec),
    Gif,
}

#[derive(Clone)]
pub enum Media {
    Still(Image),
    Video(PathBuf),
}

#[derive(Clone)]
pub struct Job {
    pub format: Format,
    pub path: PathBuf,
    pub size: (u32, u32),
    pub media: Media,
    pub crop: Option<Crop>,
    /// The look; `frame` is set per frame, and the Downscale's height follows
    /// the cropped picture (width and method from here).
    pub settings: Settings,
    /// PNG: the frame (a clip's) or the noise seed (a still's).
    pub png_frame: usize,
    /// PNG: the playhead (0…1), for the animation's values.
    pub png_t: f64,
    /// Video: bitrate and loop count; a still's length and frame rate.
    pub bitrate: u32,
    pub loops: usize,
    pub still_seconds: f64,
    pub still_fps: u32,
    pub gif_fps: u32,
    /// Keyframes (with the shader's step grid and the NTSC schema): each
    /// frame takes the animation's values at its place in the timeline.
    pub timeline: Option<(Vec<Keyframe>, HashMap<String, ShaderMeta>, Vec<NtscSetting>)>,
}

#[derive(Default)]
pub struct Progress {
    /// Thousandths done.
    pub done: AtomicU32,
    pub cancel: AtomicBool,
}

pub fn run(job: Job, progress: Arc<Progress>) -> Result<String> {
    let mut engine = Engine::new()?;
    let mut reader = match &job.media {
        Media::Video(p) => Some(VideoReader::open(p)?),
        Media::Still(_) => None,
    };
    if let Some(p) = std::env::var_os("NTSCRT_DUMP_SETTINGS") {
        let _ = std::fs::write(p, format!("{:#?}\nsize {:?} png_frame {}", job.settings, job.size, job.png_frame));
    }
    let info = reader.as_ref().map(|r| r.info());
    let evaluator = job.timeline.as_ref().and_then(|(keys, meta, ntsc)| Evaluator::new(keys, meta.clone(), ntsc));
    // The animation's values at `t` (0…1) over the look's.
    let animate = |s: &mut Settings, t: f64| {
        let Some(ev) = &evaluator else { return };
        if let Some(shader) = s.shader.as_mut() {
            let mut values: HashMap<String, f32> = shader.params.iter().cloned().collect();
            values.extend(ev.shader(t));
            shader.params = values.into_iter().collect();
            shader.params.sort_by(|a, b| a.0.cmp(&b.0));
        }
        if s.ntsc.is_some() {
            let n = ev.ntsc(t);
            if !n.is_empty() {
                s.ntsc = Some(NtscSettings::Json(ntsc_values_json(&n)));
            }
        }
    };
    // The picture for a frame (cropped), and the settings with its seed.
    let mut picture = |engine: &mut Engine, clip_frame: usize, seed: usize| -> Result<Settings> {
        let pic = match (&job.media, reader.as_mut()) {
            (Media::Video(_), Some(r)) => {
                let f = r.frame(clip_frame)?;
                Image::new(f.width, f.height, f.rgba)
            }
            (Media::Still(img), _) => img.clone(),
            _ => bail!("nothing to export"),
        };
        let pic = job.crop.map_or(pic.clone(), |c| c.apply(&pic));
        let mut s = job.settings.clone();
        if let Some(d) = s.downscale {
            s.downscale = Some(DownscaleSpec::for_width(d.width, (pic.width, pic.height), d.method));
        }
        s.frame = seed;
        engine.set_source(pic);
        Ok(s)
    };
    let tick = |i: usize, n: usize| -> Result<()> {
        progress.done.store(((i + 1) * 1000 / n.max(1)) as u32, Ordering::Relaxed);
        if progress.cancel.load(Ordering::Relaxed) {
            bail!("cancelled");
        }
        Ok(())
    };

    match job.format {
        Format::Png => {
            let seed = if info.is_some() { job.png_frame + 1 } else { job.png_frame };
            let mut s = picture(&mut engine, job.png_frame, seed)?;
            animate(&mut s, job.png_t);
            let img = engine.render_export(&s, job.size)?;
            image::RgbaImage::from_raw(img.width, img.height, img.rgba).context("image")?.save(&job.path)?;
            progress.done.store(1000, Ordering::Relaxed);
            Ok(format!("Saved {} ({} × {})", job.path.display(), job.size.0, job.size.1))
        }
        Format::Mp4(codec) => {
            let (fps, frames, loops, audio) = match info {
                Some(v) => (v.fps_rational, v.total_frames, job.loops.max(1), match &job.media {
                    Media::Video(p) => Some(p.clone()),
                    _ => None,
                }),
                None => ((job.still_fps, 1), (job.still_seconds * job.still_fps as f64).round().max(1.0) as usize, 1, None),
            };
            let mut writer = VideoWriter::create(&job.path, job.size, fps, codec, job.bitrate, audio.as_deref(), loops)?;
            let total = frames * loops;
            for i in 0..total {
                let clip_frame = i % frames;
                // Each pass renders the same frames again (seeded alike).
                let mut s = picture(&mut engine, clip_frame, clip_frame + 1)?;
                animate(&mut s, clip_frame as f64 / frames.saturating_sub(1).max(1) as f64);
                let img = engine.render_export(&s, job.size)?;
                writer.write(&img.rgba)?;
                tick(i, total)?;
            }
            writer.finish()?;
            Ok(format!("Saved {} ({} × {}, {total} frames)", job.path.display(), job.size.0, job.size.1))
        }
        Format::Gif => {
            let gif_fps = job.gif_fps.max(1) as f64;
            let (frames, clip_frame): (usize, Box<dyn Fn(usize) -> usize>) = match info {
                Some(v) => {
                    let n = ((v.total_frames as f64 / v.timescale()) * gif_fps).round().max(1.0) as usize;
                    let ts = v.timescale();
                    let last = v.total_frames.saturating_sub(1);
                    (n, Box::new(move |i| ((i as f64 / gif_fps * ts).round() as usize).min(last)))
                }
                None => ((job.still_seconds * gif_fps).round().max(1.0) as usize, Box::new(|i| i)),
            };
            let file = std::fs::File::create(&job.path)?;
            let (w, h) = (job.size.0 as u16, job.size.1 as u16);
            let mut enc = gif::Encoder::new(std::io::BufWriter::new(file), w, h, &[])?;
            enc.set_repeat(gif::Repeat::Infinite)?;
            // GIF delays are whole hundredths of a second.
            let delay = (100.0 / gif_fps).round() as u16;
            for i in 0..frames {
                let f = clip_frame(i);
                let seed = if info.is_some() { f + 1 } else { i + 1 };
                let mut s = picture(&mut engine, f, seed)?;
                animate(&mut s, i as f64 / frames.saturating_sub(1).max(1) as f64);
                let mut img = engine.render_export(&s, job.size)?;
                let mut frame = gif::Frame::from_rgba_speed(w, h, &mut img.rgba, 10);
                frame.delay = delay;
                enc.write_frame(&frame)?;
                tick(i, frames)?;
            }
            drop(enc);
            let bytes = std::fs::metadata(&job.path).map(|m| m.len()).unwrap_or(0);
            Ok(format!("Saved {} ({} × {}, {frames} frames, {:.1} MB)", job.path.display(), w, h, bytes as f64 / 1e6))
        }
    }
}
