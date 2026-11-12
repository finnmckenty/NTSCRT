//! The render thread: it owns the engine and the open picture or clip,
//! decodes the frame asked for, crops it, and renders. Only the latest
//! render request is worked on; the window shows whatever arrives last.

use std::path::PathBuf;
use std::sync::mpsc::{Receiver, Sender, TryRecvError};
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
    /// Frames of the clip baked under the current settings.
    Cached(usize),
}

/// Baking a paused clip's frames ahead of the playhead while idle: the
/// settings and crop last rendered, the next frame to look at, and how
/// many have been looked at (once round the clip, it stops).
struct Fill {
    settings: Settings,
    crop: Option<Crop>,
    next: usize,
    looked: usize,
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
    // A clip's baked frames, and which clip they're of.
    let mut cache = crate::frame_cache::FrameCache::default();
    let mut clip_id = 0u64;

    let mut fill: Option<Fill> = None;
    loop {
        let first = if fill.is_some() {
            match requests.try_recv() {
                Ok(r) => r,
                Err(TryRecvError::Disconnected) => break,
                Err(TryRecvError::Empty) => {
                    // Idle: bake the next frame not held yet.
                    let f = fill.as_mut().expect("fill");
                    let Some(Media::Video(reader)) = media.as_ref() else {
                        fill = None;
                        continue;
                    };
                    let total = reader.info().total_frames.max(1);
                    let stamp = crate::frame_cache::stamp(clip_id, f.crop, &f.settings);
                    while f.looked < total && cache.get(f.next % total, stamp).is_some() {
                        f.next += 1;
                        f.looked += 1;
                    }
                    if f.looked >= total {
                        fill = None;
                        continue;
                    }
                    let n = f.next % total;
                    let mut s = f.settings.clone();
                    s.frame = n + 1;
                    if let Some(d) = s.digital.as_mut() {
                        d.frame = n as i64;
                    }
                    let crop = f.crop;
                    let baked = (|| -> anyhow::Result<Image> {
                        let pic = reader.frame(n)?.as_ref().clone();
                        engine.set_source(match crop {
                            Some(c) => c.apply(&pic),
                            None => pic,
                        });
                        if s.digital.is_some() && clip_crop != Some(crop) {
                            clip = clip_path.as_deref().and_then(|p| crate::clip_frames::ClipFrames::open(p, crop).ok());
                            clip_crop = Some(crop);
                        }
                        let mut none = None;
                        let visitor = if s.digital.is_some() { &mut clip } else { &mut none };
                        crate::clip_frames::with_visitor(visitor, |v| engine.bake(&s, v))
                    })();
                    picture_key = None;
                    let f = fill.as_mut().expect("fill");
                    f.next += 1;
                    f.looked += 1;
                    // Out of room, or the clip won't decode there: stop.
                    let stored = baked.map(|img| cache.insert(n, stamp, img)).unwrap_or(false);
                    if stored {
                        let count = cache.count(stamp);
                        if count % 10 == 0 || f.looked >= total {
                            send(Event::Cached(count));
                        }
                    } else {
                        fill = None;
                    }
                    continue;
                }
            }
        } else {
            match requests.recv() {
                Ok(r) => r,
                Err(_) => break,
            }
        };
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
                        clip_id += 1;
                        cache.clear();
                        (picture_key, sent_key) = (None, None);
                    }
                    Err(e) => send(Event::Opened(Err(format!("{e:#}")))),
                },
                r @ Request::Render { .. } => render = Some(r),
            }
        }
        let Some(Request::Render { seq, mut settings, plan, full, frame, crop, want_source, playing }) = render else { continue };
        let t = Instant::now();
        let mut shown_frame = frame;
        let result = (|| -> anyhow::Result<Image> {
            let decode_start = Instant::now();
            // While playing, the newest frame decoded so far stands in (its
            // own noise seed and Digital frame with it).
            let is_video = matches!(media, Some(Media::Video(_)));
            let mut frame = if is_video { frame } else { 0 };
            let stamp = crate::frame_cache::stamp(clip_id, crop, &settings);
            // Baked already: no decoding, no CPU stages. (Compare needs the
            // picture itself, so it decodes.)
            if let (true, false, Some(baked)) = (is_video, want_source, cache.get(frame, stamp)) {
                let out = engine.render_preview_baked(&settings, plan, full, &baked);
                if profile {
                    eprintln!("profile frame {frame}: cached, total {:.1} ms", t.elapsed().as_secs_f64() * 1000.0);
                }
                return out;
            }
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
                shown_frame = got;
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
            let rendered = if is_video {
                // Bake it for next time.
                match crate::clip_frames::with_visitor(visitor, |v| engine.bake(&settings, v)) {
                    Ok(baked) => {
                        let out = engine.render_preview_baked(&settings, plan, full, &baked);
                        cache.insert(frame, stamp, baked);
                        out
                    }
                    Err(e) => Err(e),
                }
            } else {
                crate::clip_frames::with_visitor(visitor, |v| engine.render_preview(&settings, plan, full, v))
            };
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
        // Paused on a clip: bake ahead of the playhead while there's nothing to do.
        fill = match (&media, playing) {
            (Some(Media::Video(_)), false) => Some(Fill { settings: settings.clone(), crop, next: shown_frame + 1, looked: 0 }),
            _ => None,
        };
        if matches!(media, Some(Media::Video(_))) {
            send(Event::Cached(cache.count(crate::frame_cache::stamp(clip_id, crop, &settings))));
        }
        let source = (want_source && sent_key != picture_key).then(|| picture.clone()).flatten();
        if source.is_some() {
            sent_key = picture_key;
        }
        send(Event::Rendered { seq, result, millis: t.elapsed().as_millis(), source });
    }
}
