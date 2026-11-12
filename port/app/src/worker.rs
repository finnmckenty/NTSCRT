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
use ntscrt_media::{VideoInfo, VideoReader};

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
    },
}

pub enum Event {
    Adapter(String),
    Opened(Result<VideoInfo, String>),
    Rendered { seq: u64, result: Result<Image, String>, millis: u128, source: Option<Image> },
}

enum Media {
    Still(Image),
    Video(VideoReader),
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

    let mut media: Option<Media> = None;
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
                    (picture_key, sent_key) = (None, None);
                }
                Request::Video(path) => match VideoReader::open(&path) {
                    Ok(reader) => {
                        send(Event::Opened(Ok(reader.info())));
                        media = Some(Media::Video(reader));
                        (picture_key, sent_key) = (None, None);
                    }
                    Err(e) => send(Event::Opened(Err(format!("{e:#}")))),
                },
                r @ Request::Render { .. } => render = Some(r),
            }
        }
        let Some(Request::Render { seq, settings, plan, full, frame, crop, want_source }) = render else { continue };
        let t = Instant::now();
        let result = (|| -> anyhow::Result<Image> {
            let frame = if matches!(media, Some(Media::Video(_))) { frame } else { 0 };
            if picture_key != Some((frame, crop)) {
                let pic = match media.as_mut() {
                    Some(Media::Still(img)) => img.clone(),
                    Some(Media::Video(reader)) => {
                        let f = reader.frame(frame)?;
                        Image::new(f.width, f.height, f.rgba)
                    }
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
            engine.render_preview(&settings, plan, full)
        })()
        .map_err(|e| format!("{e:#}"));
        let source = (want_source && sent_key != picture_key).then(|| picture.clone()).flatten();
        if source.is_some() {
            sent_key = picture_key;
        }
        send(Event::Rendered { seq, result, millis: t.elapsed().as_millis(), source });
    }
}
