//! The render thread: it owns the engine and the open picture or clip,
//! decodes the frame asked for, crops it, and renders. Only the latest
//! render request is worked on; the window shows whatever arrives last.

use std::path::PathBuf;
use std::sync::mpsc::{Receiver, Sender};
use std::time::Instant;

use eframe::egui;
use ntscrt_engine::crop::Crop;
use ntscrt_engine::preview::PreviewPlan;
use ntscrt_engine::{Engine, Image, Settings};
use ntscrt_media::VideoInfo;

use crate::prefetch::Prefetch;

pub enum Request {
    Still(Image),
    Video(PathBuf),
    Render {
        seq: u64,
        settings: Settings,
        plan: PreviewPlan,
        full: bool,
        /// The clip's frame (ignored for a still).
        frame: usize,
        crop: Option<Crop>,
        /// Send the cropped picture back too (for Compare) when it changed.
        want_source: bool,
        /// Playing: the newest decoded frame up to `frame` will do.
        playing: bool,
    },
}

pub enum Event {
    Adapter(String),
    Opened(Result<VideoInfo, String>),
    Rendered { seq: u64, result: Result<Image, String>, millis: u128, source: Option<Image> },
}

enum Media {
    Still(Image),
    Video(Prefetch),
}

pub fn run(requests: Receiver<Request>, events: Sender<Event>, ctx: egui::Context) {
    let send = |e: Event| {
        let _ = events.send(e);
        ctx.request_repaint();
    };
    let mut engine = match Engine::new() {
        Ok(e) => e,
        Err(e) => {
            send(Event::Adapter(format!("No graphics device: {e}")));
            return;
        }
    };
    let a = engine.adapter_info();
    send(Event::Adapter(format!("{} ({:?})", a.name, a.backend)));

    // NTSCRT_PROFILE=1: where each preview frame's time goes, on stderr.
    let profile = std::env::var_os("NTSCRT_PROFILE").is_some();
    let mut media: Option<Media> = None;
    // The open clip's path, and its earlier frames for the Digital stage
    // (opened when the stage first needs them, per crop).
    let mut clip_path: Option<PathBuf> = None;
    let mut clip: Option<crate::clip_frames::ClipFrames> = None;
    let mut clip_crop: Option<Option<Crop>> = None;
    // What the engine's picture is: (frame, crop), and what was last sent back.
    let mut picture_key: Option<(usize, Option<Crop>)> = None;
    let mut picture: Option<Image> = None;
    let mut sent_key: Option<(usize, Option<Crop>)> = None;

    while let Ok(first) = requests.recv() {
        // New pictures and clips in order; only the latest render.
        let mut render = None;
        for r in std::iter::once(first).chain(requests.try_iter()) {
            match r {
                Request::Still(img) => {
                    media = Some(Media::Still(img));
                    (clip_path, clip, clip_crop) = (None, None, None);
                    (picture_key, sent_key) = (None, None);
                }
                Request::Video(path) => match Prefetch::open(&path) {
                    Ok(reader) => {
                        send(Event::Opened(Ok(reader.info())));
                        media = Some(Media::Video(reader));
                        (clip_path, clip, clip_crop) = (Some(path.clone()), None, None);
                        (picture_key, sent_key) = (None, None);
                    }
                    Err(e) => send(Event::Opened(Err(format!("{e:#}")))),
                },
                r @ Request::Render { .. } => render = Some(r),
            }
        }
        let Some(Request::Render { seq, mut settings, plan, full, frame, crop, want_source, playing }) = render else { continue };
        let t = Instant::now();
        let result = (|| -> anyhow::Result<Image> {
            let decode_start = Instant::now();
            // While playing, the newest frame decoded so far stands in (its
            // own noise seed and Digital frame with it).
            let mut frame = if matches!(media, Some(Media::Video(_))) { frame } else { 0 };
            let mut decoded = None;
            if let (Some(Media::Video(reader)), true) = (media.as_ref(), playing) {
                let (got, img) = reader.frame_upto(frame)?;
                if got != frame {
                    settings.frame = got + 1;
                    if let Some(d) = settings.digital.as_mut() {
                        d.frame = got as i64;
                    }
                    frame = got;
                }
                decoded = Some(img);
            }
            if picture_key != Some((frame, crop)) {
                let pic = match media.as_mut() {
                    Some(Media::Still(img)) => img.clone(),
                    Some(Media::Video(reader)) => match decoded {
                        Some(img) => img.as_ref().clone(),
                        None => reader.frame(frame)?.as_ref().clone(),
                    },
                    None => anyhow::bail!("nothing open"),
                };
                let pic = match crop {
                    Some(c) => c.apply(&pic),
                    None => pic,
                };
                engine.set_source(pic.clone());
                picture = Some(pic);
                picture_key = Some((frame, crop));
            }
            if settings.digital.is_some() && clip_path.is_some() && clip_crop != Some(crop) {
                clip = clip_path.as_deref().and_then(|p| crate::clip_frames::ClipFrames::open(p, crop).ok());
                clip_crop = Some(crop);
            }
            let decoded = decode_start.elapsed().as_secs_f64() * 1000.0;
            let mut none = None;
            let visitor = if settings.digital.is_some() { &mut clip } else { &mut none };
            let rendered = crate::clip_frames::with_visitor(visitor, |v| engine.render_preview(&settings, plan, full, v));
            if profile {
                eprintln!(
                    "profile frame {frame}: decode+crop {decoded:.1} ms, CPU stages {:.1} ms, total {:.1} ms",
                    engine.last_prepare_ms,
                    t.elapsed().as_secs_f64() * 1000.0
                );
            }
            rendered
        })()
        .map_err(|e| format!("{e:#}"));
        let source = (want_source && sent_key != picture_key).then(|| picture.clone()).flatten();
        if source.is_some() {
            sent_key = picture_key;
        }
        send(Event::Rendered { seq, result, millis: t.elapsed().as_millis(), source });
    }
}
