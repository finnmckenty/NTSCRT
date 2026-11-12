//! Screen Loop: the Mac's HowlaroundPanel and AppState+Howlaround. A
//! camcorder pointed at the TV that shows its own picture, with your look on
//! every pass. The knobs set up the camera; a short, small draft re-renders
//! as you turn them (the same render as the final one, so it shows the same
//! tunnel), and Render writes the full file with the Export settings.

use std::collections::BTreeMap;
use std::path::{Path, PathBuf};
use std::sync::atomic::Ordering;
use std::sync::mpsc::{channel, Receiver};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use eframe::egui;
use ntscrt_engine::howl::pad::{self, Handle, Pad};
use ntscrt_engine::howl::{self, Group, HowlSettings, Kind, Param, PARAMS};
use ntscrt_engine::{DownscaleSpec, HowlRender, Image};
use ntscrt_media::Codec;

use crate::export::{self, Format, Progress};
use crate::ntsc_panel::edited;
use crate::App;

/// Drafts cover the whole render up to this long: a move spans the whole
/// render, so a short draft would miss most of it.
const DRAFT_SECONDS: f64 = 10.0;
/// How far the dots may reach past the picture.
const PAD_MARGIN: f32 = 14.0;

struct Running {
    progress: Arc<Progress>,
    rx: Receiver<Result<String, String>>,
    sink: Option<Arc<Mutex<Vec<Image>>>>,
    started: Instant,
    generation: u64,
    fps: f64,
    path: PathBuf,
}

struct Draft {
    frames: Vec<Image>,
    fps: f64,
    since: Instant,
}

pub struct ScreenLoop {
    pub open: bool,
    pub values: BTreeMap<String, f64>,
    /// A still's render length (a clip's is the clip's).
    pub seconds: f64,
    generation: u64,
    draft_due: Option<Instant>,
    draft: Option<Running>,
    shown: Option<Draft>,
    texture: Option<egui::TextureHandle>,
    shown_frame: Option<usize>,
    draft_status: String,
    render: Option<Running>,
    render_status: String,
    pub last_output: Option<PathBuf>,
    drag: Option<(Handle, Pad, egui::Pos2)>,
    selected: Option<Handle>,
    /// NTSCRT_SCREEN_LOOP_RENDER: render there once open, then quit.
    pub auto_render: Option<PathBuf>,
}

impl Default for ScreenLoop {
    fn default() -> Self {
        Self {
            open: false,
            values: Param::default_values(),
            seconds: 5.0,
            generation: 0,
            draft_due: None,
            draft: None,
            shown: None,
            texture: None,
            shown_frame: None,
            draft_status: String::new(),
            render: None,
            render_status: String::new(),
            last_output: None,
            drag: None,
            selected: None,
            auto_render: None,
        }
    }
}

/// Screen Loop presets: bundled (presets/Screen Loop next to the looks) and
/// yours (the user folder), by name, yours winning.
fn preset_folders(presets: Option<&Path>) -> (Option<PathBuf>, PathBuf) {
    let bundled = presets.map(|p| p.join("Screen Loop")).filter(|p| p.is_dir());
    let user = std::env::var_os("APPDATA")
        .map(PathBuf::from)
        .or_else(|| std::env::var_os("HOME").map(|h| PathBuf::from(h).join("Library/Application Support")))
        .unwrap_or_else(|| PathBuf::from("."))
        .join("NTSCRT")
        .join("Screen Loop");
    (bundled, user)
}

fn discover(presets: Option<&Path>) -> Vec<(String, PathBuf)> {
    let (bundled, user) = preset_folders(presets);
    let mut by_name: BTreeMap<String, PathBuf> = BTreeMap::new();
    for folder in bundled.into_iter().chain(std::iter::once(user)) {
        let Ok(items) = std::fs::read_dir(&folder) else { continue };
        for e in items.flatten() {
            let p = e.path();
            if p.extension().is_some_and(|x| x.eq_ignore_ascii_case("json")) {
                if let Some(name) = p.file_stem() {
                    by_name.insert(name.to_string_lossy().into_owned(), p);
                }
            }
        }
    }
    let mut list: Vec<_> = by_name.into_iter().collect();
    list.sort_by_key(|(n, _)| n.to_lowercase());
    list
}

fn timestamp() -> String {
    let secs = std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).map_or(0, |d| d.as_secs());
    format!("{secs}")
}

impl ScreenLoop {
    pub fn new(auto_render: Option<PathBuf>) -> Self {
        Self { auto_render, ..Default::default() }
    }

    pub fn rendering(&self) -> bool {
        self.render.is_some()
    }
}

impl App {
    pub(crate) fn howl_settings(&self) -> HowlSettings {
        HowlSettings::new(&self.screen_loop.values)
    }

    /// The whole render's length in seconds: what a move spans.
    fn howl_length(&self) -> f64 {
        self.video.map_or(self.screen_loop.seconds, |v| v.duration)
    }

    /// The draft's size: small, so it comes back in a second or two. The loop
    /// itself runs at a fixed size, so the draft shows the same tunnel.
    fn draft_size(&self) -> (u32, u32) {
        let (w, h) = self.picture_size().unwrap_or((640, 480));
        let aspect = w as f64 / h.max(1) as f64;
        let long = 480.0;
        let (w, h) = if aspect >= 1.0 { (long, long / aspect) } else { (long * aspect, long) };
        (((w.round() as u32).max(64)) & !1, ((h.round() as u32).max(64)) & !1)
    }

    fn set_howl_values(&mut self, values: &[(&str, f64)]) {
        if values.iter().any(|(k, v)| self.screen_loop.values.get(*k) != Some(v)) {
            for (k, v) in values {
                self.screen_loop.values.insert(k.to_string(), *v);
            }
            self.schedule_draft(Duration::from_millis(350));
        }
    }

    /// Re-render the draft shortly after the knobs stop moving; a draft still
    /// running is canceled.
    pub(crate) fn schedule_draft(&mut self, delay: Duration) {
        if let Some(d) = &self.screen_loop.draft {
            d.progress.cancel.store(true, Ordering::Relaxed);
        }
        self.screen_loop.generation += 1;
        self.screen_loop.draft_due = Some(Instant::now() + delay);
    }

    /// A Screen Loop render of the current look: as an export would be, with
    /// the camera, without Digital video (and so without One field).
    fn howl_job(&mut self, format: Format, path: PathBuf, size: (u32, u32), draft: bool) -> Option<(export::Job, f64)> {
        let picture = self.picture_size()?;
        let mut job = self.export_job(format, path, size)?;
        job.settings.digital = None;
        job.settings.downscale = self.downscale.then(|| DownscaleSpec::for_width(self.downscale_width, picture, self.method));
        let length = self.howl_length();
        job.howl = Some(HowlRender { settings: self.howl_settings(), length });
        let fps = self.video.map_or(self.timeline_fps as f64, |v| (v.fps as f32).max(1.0) as f64);
        if draft {
            job.loops = 1;
            match self.video {
                Some(_) => job.frame_limit = Some(((DRAFT_SECONDS.min(length)) * fps).round().max(1.0) as usize),
                None => job.still_seconds = self.screen_loop.seconds.min(DRAFT_SECONDS),
            }
            job.sink = Some(Arc::new(Mutex::new(Vec::new())));
        } else {
            job.still_seconds = self.screen_loop.seconds;
            // A still's repeats are rendered frames (a clip repeats in passes).
            if self.video.is_none() && matches!(format, Format::Mp4(_)) {
                job.still_seconds *= self.export_loops.max(1) as f64;
            }
            if format == Format::Gif {
                job.loops = 1;
            }
        }
        job.still_fps = self.timeline_fps;
        Some((job, fps))
    }

    fn spawn(&self, job: export::Job, fps: f64, generation: u64) -> Running {
        let progress = Arc::new(Progress::default());
        let (tx, rx) = channel();
        let p = progress.clone();
        let sink = job.sink.clone();
        let path = job.path.clone();
        std::thread::spawn(move || {
            let _ = tx.send(export::run(job, p).map_err(|e| format!("{e:#}")));
        });
        Running { progress, rx, sink, started: Instant::now(), generation, fps, path }
    }

    fn start_draft(&mut self) {
        let size = self.draft_size();
        let Some((job, fps)) = self.howl_job(Format::Frames, PathBuf::from("draft"), size, true) else { return };
        let generation = self.screen_loop.generation;
        self.screen_loop.draft = Some(self.spawn(job, fps, generation));
        self.screen_loop.draft_status = "Rendering draft…".into();
    }

    /// Render the whole Screen Loop to `path` with the Export settings.
    pub(crate) fn render_screen_loop(&mut self, path: PathBuf) {
        let format = match self.export_format {
            Format::Png | Format::Frames => Format::Mp4(Codec::H264),
            f => f,
        };
        // The file's extension decides between GIF and MP4.
        let gif = path.extension().is_some_and(|x| x.eq_ignore_ascii_case("gif"));
        let format = match (gif, format) {
            (true, _) => Format::Gif,
            (false, Format::Gif) => Format::Mp4(Codec::H264),
            (false, f) => f,
        };
        if format == Format::Gif && self.export_format != Format::Gif {
            self.export_format = Format::Gif;
        }
        let Some(size) = self.export_size() else { return };
        let Some((job, fps)) = self.howl_job(format, path, size, false) else { return };
        if let Some(d) = self.screen_loop.draft.take() {
            d.progress.cancel.store(true, Ordering::Relaxed);
        }
        self.screen_loop.draft_due = None;
        self.screen_loop.render = Some(self.spawn(job, fps, 0));
        self.screen_loop.render_status = "Rendering…".into();
        self.screen_loop.last_output = None;
    }

    fn ask_and_render(&mut self) {
        let ext = if self.export_format == Format::Gif { "gif" } else { "mp4" };
        if let Some(p) = rfd::FileDialog::new().add_filter(ext.to_uppercase(), &[ext]).set_file_name(format!("screen loop {}.{ext}", timestamp())).save_file() {
            self.render_screen_loop(p);
        }
    }

    /// Finished drafts and renders; the next draft when it's due.
    fn poll_screen_loop(&mut self, ctx: &egui::Context) {
        let sl = &mut self.screen_loop;
        if let Some(d) = &sl.draft {
            if let Ok(result) = d.rx.try_recv() {
                let d = sl.draft.take().expect("draft");
                match result {
                    Ok(_) if d.generation == sl.generation => {
                        let frames = d.sink.map(|s| std::mem::take(&mut *s.lock().expect("sink"))).unwrap_or_default();
                        let n = frames.len();
                        let width = frames.first().map_or(0, |f| f.width);
                        sl.shown = Some(Draft { frames, fps: d.fps, since: Instant::now() });
                        sl.shown_frame = None;
                        sl.draft_status = format!(
                            "Draft · {:.1} s at {width} px · rendered in {:.1} s",
                            n as f64 / d.fps.max(1.0),
                            d.started.elapsed().as_secs_f64()
                        );
                    }
                    Ok(_) => {}
                    Err(e) if e.contains("cancelled") => {}
                    Err(e) => sl.draft_status = format!("Draft failed: {e}"),
                }
            } else {
                ctx.request_repaint_after(Duration::from_millis(100));
            }
        }
        if let Some(r) = &sl.render {
            if let Ok(result) = r.rx.try_recv() {
                let r = sl.render.take().expect("render");
                match result {
                    Ok(msg) => {
                        sl.render_status = msg;
                        sl.last_output = Some(r.path);
                    }
                    Err(e) if e.contains("cancelled") => {
                        let _ = std::fs::remove_file(&r.path);
                        sl.render_status = "Render canceled".into();
                    }
                    Err(e) => sl.render_status = format!("Render failed: {e}"),
                }
                if let Some(path) = sl.auto_render.take() {
                    let _ = std::fs::write(path.with_extension("log"), &sl.render_status);
                    ctx.send_viewport_cmd(egui::ViewportCommand::Close);
                }
            } else {
                ctx.request_repaint_after(Duration::from_millis(100));
            }
        }
        if sl.open && sl.render.is_none() && sl.draft.is_none() {
            if let Some(due) = sl.draft_due {
                if Instant::now() >= due {
                    sl.draft_due = None;
                    self.start_draft();
                } else {
                    ctx.request_repaint_after(due - Instant::now());
                }
            }
        }
    }

    pub(crate) fn screen_loop_window(&mut self, ctx: &egui::Context) {
        self.poll_screen_loop(ctx);
        if !self.screen_loop.open {
            return;
        }
        if let Some(path) = self.screen_loop.auto_render.clone() {
            if self.screen_loop.render.is_none() && self.screen_loop.last_output.is_none() && self.screen_loop.render_status.is_empty() {
                self.render_screen_loop(path);
            }
        }
        let builder = egui::ViewportBuilder::default().with_title("Screen Loop").with_inner_size([1060.0, 720.0]).with_min_inner_size([760.0, 520.0]);
        ctx.show_viewport_immediate(egui::ViewportId::from_hash_of("screen-loop"), builder, |ui, _class| {
            if ui.ctx().input(|i| i.viewport().close_requested()) {
                self.close_screen_loop();
                return;
            }
            egui::Panel::bottom("sl-footer").show(ui, |ui| {
                ui.add_space(6.0);
                self.footer(ui);
                ui.add_space(6.0);
            });
            egui::Panel::right("sl-knobs").resizable(false).exact_size(350.0).show(ui, |ui| {
                egui::ScrollArea::vertical().auto_shrink(false).show(ui, |ui| {
                    ui.spacing_mut().slider_width = 220.0;
                    self.knobs(ui);
                });
            });
            egui::CentralPanel::default().show(ui, |ui| self.draft_view(ui));
        });
    }

    pub(crate) fn open_screen_loop(&mut self) {
        self.playing = None;
        self.timeline_playing = None;
        self.screen_loop.open = true;
        // The look may have changed since the last draft.
        self.schedule_draft(Duration::ZERO);
    }

    pub(crate) fn close_screen_loop(&mut self) {
        self.screen_loop.open = false;
        if let Some(d) = self.screen_loop.draft.take() {
            d.progress.cancel.store(true, Ordering::Relaxed);
        }
        self.screen_loop.draft_due = None;
    }

    fn draft_view(&mut self, ui: &mut egui::Ui) {
        let readout = self.readout();
        let avail = ui.available_rect_before_wrap();
        let area = egui::Rect::from_min_max(avail.min, egui::pos2(avail.max.x, avail.max.y - 44.0));
        let (w, h) = self.draft_size();
        // The picture fitted and centered, inside a margin for the dots.
        let room = area.shrink(PAD_MARGIN);
        let scale = (room.width() / w as f32).min(room.height() / h as f32);
        let pic = egui::Rect::from_center_size(room.center(), egui::vec2(w as f32 * scale, h as f32 * scale));
        let response = ui.allocate_rect(area, egui::Sense::click_and_drag());
        let painter = ui.painter_at(avail);
        painter.rect_filled(pic, 6.0, egui::Color32::BLACK);

        // The draft, playing on a loop.
        if let Some(d) = &self.screen_loop.shown {
            if !d.frames.is_empty() {
                let i = ((d.since.elapsed().as_secs_f64() * d.fps) as usize) % d.frames.len();
                if self.screen_loop.shown_frame != Some(i) || self.screen_loop.texture.is_none() {
                    let f = &d.frames[i];
                    let image = egui::ColorImage::from_rgba_unmultiplied([f.width as usize, f.height as usize], &f.rgba);
                    match &mut self.screen_loop.texture {
                        Some(t) => t.set(image, egui::TextureOptions::LINEAR),
                        None => self.screen_loop.texture = Some(ui.ctx().load_texture("screen-loop-draft", image, egui::TextureOptions::LINEAR)),
                    }
                    self.screen_loop.shown_frame = Some(i);
                }
                if let Some(t) = &self.screen_loop.texture {
                    painter.image(t.id(), pic, egui::Rect::from_min_max(egui::pos2(0.0, 0.0), egui::pos2(1.0, 1.0)), egui::Color32::WHITE);
                }
                ui.ctx().request_repaint_after(Duration::from_secs_f64(1.0 / d.fps.max(1.0)));
            }
        } else {
            painter.text(pic.center(), egui::Align2::CENTER_CENTER, "Rendering the first draft…", egui::FontId::proportional(14.0), egui::Color32::GRAY);
        }
        if let Some(d) = &self.screen_loop.draft {
            let done = d.progress.done.load(Ordering::Relaxed) as f32 / 10.0;
            let label = format!("Updating draft… {done:.0}%");
            let at = pic.center_top() + egui::vec2(0.0, 22.0);
            let galley = painter.layout_no_wrap(label, egui::FontId::proportional(12.0), egui::Color32::WHITE);
            let bg = egui::Rect::from_center_size(at, galley.size() + egui::vec2(20.0, 10.0));
            painter.rect_filled(bg, 12.0, egui::Color32::from_black_alpha(160));
            painter.galley(bg.center() - galley.size() / 2.0, galley, egui::Color32::WHITE);
        }

        // The vanishing point and drift, dragged on the picture.
        let settings = self.howl_settings();
        let frame = (pic.left() as f64, pic.top() as f64, pic.width() as f64, pic.height() as f64);
        let pad = Pad::new(frame, &settings);
        self.draw_pad(&painter, &pad, &settings);
        if settings.tv_in_view() {
            if response.drag_started() || response.double_clicked() || response.clicked() {
                if let Some(pos) = response.interact_pointer_pos() {
                    let hit = pad.handle((pos.x as f64, pos.y as f64));
                    if response.double_clicked() {
                        if let Some(handle) = hit {
                            let p = pad.double_clicked(handle);
                            self.set_howl_values(&p.values());
                        }
                    } else if response.drag_started() {
                        self.screen_loop.drag = hit.map(|h| (h, pad, pos));
                    }
                    if hit.is_some() {
                        self.screen_loop.selected = hit;
                    }
                }
            }
            if let (Some((handle, from, at)), Some(pos)) = (self.screen_loop.drag, response.interact_pointer_pos()) {
                if response.dragged() {
                    let p = from.dragged(handle, ((pos.x - at.x) as f64, (pos.y - at.y) as f64));
                    self.set_howl_values(&p.values());
                }
            }
            if response.drag_stopped() {
                self.screen_loop.drag = None;
            }
            // Arrow keys nudge the dot clicked last (Shift: 10%).
            if let Some(handle) = self.screen_loop.selected {
                let (dx, dy, shift) = ui.input(|i| {
                    let k = |key| i.key_pressed(key) as i32;
                    (k(egui::Key::ArrowRight) - k(egui::Key::ArrowLeft), k(egui::Key::ArrowDown) - k(egui::Key::ArrowUp), i.modifiers.shift)
                });
                if (dx, dy) != (0, 0) && !ui.ctx().egui_wants_keyboard_input() {
                    let p = pad.nudged(handle, dx, dy, if shift { 0.1 } else { 0.01 });
                    self.set_howl_values(&p.values());
                }
            }
            if self.screen_loop.drag.is_none() {
                if let Some(pos) = response.hover_pos() {
                    let tip = match pad.handle((pos.x as f64, pos.y as f64)) {
                        Some(Handle::End) if pad.stacked() => Some("Pull this blue ring out of the green dot to make the vanishing point drift over the render. Drag the green dot itself to move the vanishing point."),
                        Some(Handle::End) => Some("Drift to: where the vanishing point moves over the render. Drag it back onto the green dot, or double-click it, for no drift."),
                        Some(Handle::Start) => Some("Vanishing point: where the copies converge at the start. Drag to move it; double-click for the middle. Arrow keys nudge the dot you clicked last."),
                        Some(Handle::Both) => Some("Drag the arrow to move the vanishing point and its drift together."),
                        None => None,
                    };
                    if let Some(tip) = tip {
                        response.clone().on_hover_text(tip);
                    }
                }
            }
        }
        let text_at = egui::pos2(area.left() + PAD_MARGIN, area.bottom() + 4.0);
        painter.text(text_at, egui::Align2::LEFT_TOP, readout, egui::FontId::proportional(13.0), ui.visuals().text_color());
        painter.text(text_at + egui::vec2(0.0, 18.0), egui::Align2::LEFT_TOP, &self.screen_loop.draft_status, egui::FontId::proportional(11.0), ui.visuals().weak_text_color());
    }

    fn draw_pad(&self, painter: &egui::Painter, pad: &Pad, settings: &HowlSettings) {
        let fade = if settings.tv_in_view() { 1.0 } else { 0.35 };
        let c = |r: u8, g: u8, b: u8, a: f32| egui::Color32::from_rgba_unmultiplied(r, g, b, (a * fade * 255.0) as u8);
        let pt = |p: (f64, f64)| egui::pos2(p.0 as f32, p.1 as f32);
        let (s, e) = (pt(pad.start_point()), pt(pad.end_point()));
        let shadow = c(0, 0, 0, 0.5);
        // How far the hands take the vanishing point.
        let reach = settings.handheld_reach(self.howl_length());
        if reach.0 > 0.0 || reach.1 > 0.0 {
            let grow = pad::DOT_RADIUS as f32 + 2.0;
            let r = egui::vec2(reach.0 as f32 * pad.frame.2 as f32 + grow, reach.1 as f32 * pad.frame.3 as f32 + grow);
            painter.add(egui::Shape::ellipse_filled(s, r, c(255, 255, 255, 0.07)));
            painter.add(egui::Shape::ellipse_stroke(s, r, egui::Stroke::new(2.5, c(0, 0, 0, 0.3))));
            painter.add(egui::Shape::ellipse_stroke(s, r, egui::Stroke::new(1.0, c(255, 255, 255, 0.6))));
        }
        if self.screen_loop.drag.is_some() {
            let f = pad.frame;
            let (mx, my) = ((f.0 + f.2 / 2.0) as f32, (f.1 + f.3 / 2.0) as f32);
            let guide = egui::Stroke::new(1.0, c(255, 255, 255, 0.22));
            painter.line_segment([egui::pos2(mx, f.1 as f32), egui::pos2(mx, (f.1 + f.3) as f32)], guide);
            painter.line_segment([egui::pos2(f.0 as f32, my), egui::pos2((f.0 + f.2) as f32, my)], guide);
        }
        // The arrow, a head at each end when the move goes out and back.
        if !pad.stacked() {
            let d = e - s;
            let length = d.length().max(0.001);
            let u = d / length;
            let (from, to) = (pad::DOT_RADIUS as f32 + 3.0, length - pad::RING_RADIUS as f32 - 3.0);
            if to - from > 4.0 {
                let (a, b) = (s + u * from, s + u * to);
                let size = 9.0f32.min((to - from) / 2.0);
                let half = size * 0.55;
                let head = |tip: egui::Pos2, dir: egui::Vec2| {
                    let n = egui::vec2(-dir.y, dir.x);
                    vec![tip - dir * size + n * half, tip, tip - dir * size - n * half]
                };
                for (width, color) in [(4.5, shadow), (2.0, c(255, 255, 255, 1.0))] {
                    let stroke = egui::Stroke::new(width, color);
                    painter.line_segment([a, b], stroke);
                    painter.add(egui::Shape::line(head(b, u), stroke));
                    if settings.looped() {
                        painter.add(egui::Shape::line(head(a, -u), stroke));
                    }
                }
            }
        }
        let blue = c(69, 143, 255, 1.0);
        let green = c(64, 219, 107, 1.0);
        let r = pad::RING_RADIUS as f32;
        painter.circle_stroke(e, r, egui::Stroke::new(5.5, shadow));
        painter.circle_stroke(e, r, egui::Stroke::new(3.0, blue));
        let d = pad::DOT_RADIUS as f32;
        painter.circle_stroke(s, d, egui::Stroke::new(3.5, shadow));
        painter.circle_filled(s, d, green);
        painter.circle_stroke(s, d, egui::Stroke::new(1.5, c(255, 255, 255, 1.0)));
        match self.screen_loop.selected {
            Some(Handle::End) => {
                painter.circle_stroke(e, r + 4.5, egui::Stroke::new(1.5, c(255, 255, 255, 0.9)));
            }
            Some(Handle::Start) => {
                painter.circle_stroke(s, if pad.stacked() { d + 2.0 } else { d + 4.0 }, egui::Stroke::new(1.5, c(255, 255, 255, 0.9)));
            }
            _ => {}
        }
    }

    /// The vanishing point and drift in words, under the preview.
    fn readout(&self) -> String {
        let s = self.howl_settings();
        if !s.tv_in_view() {
            return "Zoom is 0%: the camera doesn't see the TV, so there's no tunnel.".into();
        }
        let start = howl::describe(s.vanishing_point());
        let mut text = format!("Vanishing point {}", if start == "the middle" { "in the middle".to_string() } else { start });
        if s.drift_target() == s.vanishing_point() {
            text += " · no drift";
        } else {
            text += &format!(" · drifts to {}{}", howl::describe(s.drift_target()), if s.looped() { " and back" } else { "" });
        }
        text
    }

    fn copies_caption(&self) -> String {
        let s = self.howl_settings();
        if !s.tv_in_view() {
            return "The camera doesn't see the TV — no feedback.".into();
        }
        let (w, h) = self.picture_size().unwrap_or((640, 480));
        let chain = if self.downscale { DownscaleSpec::for_width(self.downscale_width, (w, h), self.method).height } else { h };
        match s.visible_copies(w as f64 / h.max(1) as f64, chain.max(16)) {
            None => "Copies grow instead of shrinking — the feedback swirls.".into(),
            Some(n) if n >= 200 => "200+ copies deep".into(),
            Some(n) => format!("≈ {n} cop{} deep", if n == 1 { "y" } else { "ies" }),
        }
    }

    fn knobs(&mut self, ui: &mut egui::Ui) {
        ui.add_space(6.0);
        ui.horizontal(|ui| {
            ui.heading("Screen Loop");
            ui.with_layout(egui::Layout::right_to_left(egui::Align::Center), |ui| {
                if ui.small_button("Reset").clicked() {
                    self.screen_loop.values = Param::default_values();
                    self.schedule_draft(Duration::from_millis(350));
                }
                self.presets_menu(ui);
            });
        });
        ui.weak("A camcorder pointed at the TV that's showing its own picture. Every copy has been through your whole look once more than the one around it.");
        let mut changes: Vec<(&'static str, f64)> = Vec::new();
        let settings = self.howl_settings();
        for group in Group::ALL {
            ui.add_space(8.0);
            ui.strong(group.label());
            if group == Group::Framing {
                ui.weak("On the preview, drag the green dot to set the vanishing point, and pull the blue ring out of it to make the point drift.");
            }
            for p in PARAMS.iter().filter(|p| p.group == group && !p.is_position()) {
                let v = settings.get(p.id);
                let idle = p.id == "seed" && settings.get("shake") == 0.0;
                ui.add_enabled_ui(!idle, |ui| match p.kind {
                    Kind::Toggle => {
                        let mut on = v >= 0.5;
                        if ui.checkbox(&mut on, p.label).on_hover_text(p.help).clicked() {
                            changes.push((p.id, if on { 1.0 } else { 0.0 }));
                        }
                    }
                    Kind::Slider { min, max, percent, unit, step } => {
                        let scale = if percent { 100.0 } else { 1.0 };
                        ui.horizontal(|ui| {
                            ui.label(p.label).on_hover_text(p.help);
                            ui.with_layout(egui::Layout::right_to_left(egui::Align::Center), |ui| {
                                let (mag, side) = p.reading(v);
                                let text = if p.sides.is_some() {
                                    if mag == 0.0 { side.to_string() } else { format!("{:.0}{} {side}", mag * scale, if percent { "%" } else { unit }) }
                                } else if percent {
                                    format!("{:.0}%", v * 100.0)
                                } else if unit == "frames" && v == 1.0 {
                                    "1 frame".into()
                                } else {
                                    format!("{}{}{unit}", if step.is_some() { format!("{v:.0}") } else { format!("{v:.1}") }, if unit.is_empty() || unit.starts_with('°') { "" } else { " " })
                                };
                                ui.weak(text);
                            });
                        });
                        let mut shown = v;
                        let mut slider = egui::Slider::new(&mut shown, min..=max).show_value(false);
                        if let Some(s) = step {
                            slider = slider.step_by(s);
                        }
                        let r = ui.add(slider).on_hover_text(p.help);
                        if r.double_clicked() {
                            changes.push((p.id, p.neutral_value));
                        } else if edited(&r) {
                            changes.push((p.id, step.map_or(shown, |s| (shown / s).round() * s)));
                        }
                        let ends = p.sides.map(|s| (s.negative, s.positive)).or(p.ends);
                        if let Some((lo, hi)) = ends {
                            ui.horizontal(|ui| {
                                let cap = |w: &str| {
                                    let mut c = w.chars();
                                    c.next().map(|f| f.to_uppercase().collect::<String>() + c.as_str()).unwrap_or_default()
                                };
                                ui.small(cap(lo));
                                ui.with_layout(egui::Layout::right_to_left(egui::Align::Center), |ui| ui.small(cap(hi)));
                            });
                        }
                        if p.id == "zoom" {
                            ui.weak(self.copies_caption());
                        }
                    }
                    Kind::Position { .. } => {}
                });
            }
        }
        if !changes.is_empty() {
            self.set_howl_values(&changes);
        }
    }

    fn presets_menu(&mut self, ui: &mut egui::Ui) {
        ui.menu_button("Presets", |ui| {
            let (_, user) = preset_folders(self.presets.as_deref());
            if ui.button("Save Preset…").clicked() {
                let _ = std::fs::create_dir_all(&user);
                if let Some(p) = rfd::FileDialog::new().add_filter("Screen Loop preset", &["json"]).set_directory(&user).set_file_name(format!("Screen loop {}.json", timestamp())).save_file() {
                    let seconds = self.video.is_none().then_some(self.screen_loop.seconds);
                    if let Err(e) = std::fs::write(&p, self.howl_settings().to_preset(seconds)) {
                        self.screen_loop.render_status = format!("Couldn't save the preset: {e}");
                    }
                }
                ui.close();
            }
            if ui.button("Load Preset…").clicked() {
                if let Some(p) = rfd::FileDialog::new().add_filter("Screen Loop preset", &["json"]).set_directory(&user).pick_file() {
                    self.load_screen_loop_preset(&p);
                }
                ui.close();
            }
            let list = discover(self.presets.as_deref());
            if !list.is_empty() {
                ui.separator();
                for (name, path) in list {
                    if ui.button(name).clicked() {
                        self.load_screen_loop_preset(&path);
                        ui.close();
                    }
                }
            }
        })
        .response
        .on_hover_text("Save the camera's settings as a Screen Loop preset, or load one. They live in their own folder, apart from the look presets.");
    }

    pub(crate) fn load_screen_loop_preset(&mut self, path: &Path) {
        match std::fs::read_to_string(path).map_err(anyhow::Error::from).and_then(|j| HowlSettings::from_preset(&j)) {
            Ok((s, seconds)) => {
                self.screen_loop.values = s.values;
                if let Some(sec) = seconds {
                    self.screen_loop.seconds = sec;
                }
                self.schedule_draft(Duration::from_millis(50));
            }
            Err(e) => self.screen_loop.render_status = format!("Couldn't load the preset: {e:#}"),
        }
    }

    fn footer(&mut self, ui: &mut egui::Ui) {
        ui.horizontal(|ui| {
            match self.video {
                Some(v) => {
                    ui.weak(format!("{:.1} s, the whole clip", v.duration));
                }
                None => {
                    ui.label("Length");
                    let before = self.screen_loop.seconds;
                    ui.add(egui::DragValue::new(&mut self.screen_loop.seconds).range(0.5..=60.0).speed(0.1).suffix(" s"));
                    if before != self.screen_loop.seconds {
                        self.schedule_draft(Duration::from_millis(500));
                    }
                }
            }
            let format = match self.export_format {
                Format::Gif => "GIF".to_string(),
                Format::Mp4(Codec::Hevc) => "MP4 (HEVC)".to_string(),
                _ => "MP4 (H.264)".to_string(),
            };
            let size = self.export_size().map_or(String::new(), |(w, h)| format!(" · {w} × {h}"));
            if ui.button(format!("{format}{size}…")).on_hover_text("Format, size and quality for the render: the Export settings, shared with the Export window.").clicked() {
                self.export_open = true;
                if self.export_format == Format::Png {
                    self.export_format = Format::Mp4(Codec::H264);
                }
            }
            ui.with_layout(egui::Layout::right_to_left(egui::Align::Center), |ui| {
                let working = self.screen_loop.render.is_some();
                if ui.add_enabled(!working, egui::Button::new("Render…")).clicked() {
                    self.ask_and_render();
                }
                if working {
                    if ui.button("Cancel").clicked() {
                        if let Some(r) = &self.screen_loop.render {
                            r.progress.cancel.store(true, Ordering::Relaxed);
                        }
                    }
                } else if ui.button("Close").clicked() {
                    self.close_screen_loop();
                }
                if let (Some(out), false) = (self.screen_loop.last_output.clone(), working) {
                    if ui.button("Show in folder").clicked() {
                        crate::reveal(&out);
                    }
                }
                match &self.screen_loop.render {
                    Some(r) => {
                        let done = r.progress.done.load(Ordering::Relaxed) as f32 / 1000.0;
                        ui.label("Rendering…");
                        ui.add(egui::ProgressBar::new(done).desired_width(120.0));
                    }
                    None => {
                        if !self.screen_loop.render_status.is_empty() {
                            ui.weak(&self.screen_loop.render_status);
                        }
                    }
                }
            });
        });
    }
}
