//! NTSCRT for Windows — first skeleton: open a picture, NTSC on/off, the
//! Downscale, a CRT shader, and a live preview. Rendering runs on a worker
//! thread that owns the engine; the window shows the latest frame.
//!
//! Hooks (for checking it headlessly):
//! - `NTSCRT_SOURCE=<image>` (or a path argument): open it at launch.
//! - `NTSCRT_UI_SNAPSHOT=<png>`: once the first frame is on screen, save a
//!   screenshot of the window there and quit.

#![cfg_attr(not(debug_assertions), windows_subsystem = "windows")]

mod export;
mod ntsc_panel;
mod shader_panel;
mod worker;

use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::sync::mpsc::{channel, Receiver, Sender};

use ntscrt_media::{Codec, VideoInfo};
use std::sync::Arc;
use worker::{Event, Request};
use std::time::{Duration, Instant};

use eframe::egui;
use ntscrt_engine::serde_json::{Map, Value};
use ntscrt_engine::{
    app_shader_defaults, find_presets, find_shaders, write_look, Look, LookState, ntsc_default_values, ntsc_settings, ntsc_values_json, preset_parameters, DownscaleMethod,
    DownscaleSpec, Image, NtscSetting, NtscSettings, Settings, ShaderParam, ShaderSpec, CRT_SHADERS,
};
use ntscrt_engine::crop::{Crop, Ratio};
use ntscrt_engine::preview::{self, PreviewPlan};

const SIDEBAR_WIDTH: f32 = 330.0;

struct Rendered {
    seq: u64,
    result: Result<Image, String>,
    millis: u128,
}

struct App {
    requests: Sender<Request>,
    events: Receiver<Event>,
    adapter: String,
    shaders: Option<PathBuf>,

    source: Option<(String, u32, u32)>,
    downscale: bool,
    downscale_width: u32,
    method: DownscaleMethod,
    ntsc: bool,
    ntsc_settings: Vec<NtscSetting>,
    ntsc_values: Map<String, Value>,
    crt: bool,
    shader: usize,
    /// Each shader's parameters (as its preset declares them), loaded on first use.
    shader_params: HashMap<usize, Result<Vec<ShaderParam>, String>>,
    /// Each shader's current values; kept when switching between shaders.
    shader_values: HashMap<usize, HashMap<String, f32>>,

    presets: Option<PathBuf>,
    /// The look last loaded: its name, the file's other sections (written
    /// back on save), and what it uses that isn't here yet.
    look_name: Option<String>,
    look_raw: Option<Map<String, Value>>,
    look_notes: Vec<&'static str>,
    downscale_preset: String,

    // Preview (the Mac's palette: Compare, Integer scale, Animate, Zoom).
    integer_scale: bool,
    zoom: f32,
    /// Pan in normalized picture space.
    pan: egui::Vec2,
    compare: bool,
    compare_x: f32,
    dragging_compare: bool,
    animate: bool,
    /// Seeds the NTSC noise and is the shader's frame count; advances while
    /// Animate is on (the Mac's frameCounter).
    frame: usize,
    last_tick: Instant,
    source_texture: Option<egui::TextureHandle>,
    /// The picture as the chain sees it (cropped), for Compare.
    source_pixels: Option<Image>,
    /// The picture's or clip's size as opened (before the crop).
    original_size: Option<(u32, u32)>,
    /// The open clip, if it's a video.
    video: Option<VideoInfo>,
    /// The clip's frame on screen, and playback (started at, from frame).
    video_frame: usize,
    playing: Option<(Instant, usize)>,
    crop_enabled: bool,
    crop: Crop,
    /// Dragging the picture: the crop and pointer where the drag began.
    crop_drag: Option<(Crop, egui::Pos2)>,

    seq: u64,
    sent: Option<(Settings, PreviewPlan, bool, usize, Option<Crop>, bool)>,
    texture: Option<egui::TextureHandle>,
    shown_seq: u64,
    status: String,
    error: Option<String>,

    // Export (the Mac's popover, as a window).
    export_open: bool,
    export_format: export::Format,
    export_long_edge: u32,
    export_quality: usize,
    export_loops: usize,
    export_snap: bool,
    gif_width: u32,
    gif_fps: u32,
    still_seconds: f64,
    still_fps: u32,
    export_job: Option<(Arc<export::Progress>, Receiver<Result<String, String>>)>,
    export_status: String,
    /// The still as opened (exports render it on their own engine), or the clip's path.
    still: Option<Image>,
    source_path: Option<PathBuf>,

    snapshot: Option<PathBuf>,
    snapshot_requested: bool,
    /// NTSCRT_SNAPSHOT_AFTER=seconds: wait this long first.
    snapshot_after: Option<(Instant, f64)>,
    /// NTSCRT_PLAY=1: play the clip as soon as it's open.
    autoplay: bool,
    /// NTSCRT_EXPORT=<file>: export there once the preview is up, then quit.
    auto_export: Option<PathBuf>,
}

impl App {
    fn new(cc: &eframe::CreationContext) -> Self {
        let (req_tx, req_rx) = channel();
        let (ev_tx, ev_rx) = channel();
        let ctx = cc.egui_ctx.clone();
        std::thread::spawn(move || worker::run(req_rx, ev_tx, ctx));
        let mut app = Self {
            requests: req_tx,
            events: ev_rx,
            adapter: "starting…".into(),
            shaders: find_shaders(),
            source: None,
            downscale: true,
            downscale_width: 320,
            method: DownscaleMethod::Nearest,
            ntsc: true,
            ntsc_settings: ntsc_settings(),
            ntsc_values: ntsc_default_values(),
            crt: true,
            shader_params: HashMap::new(),
            shader_values: HashMap::new(),
            presets: find_presets(),
            look_name: None,
            look_raw: None,
            look_notes: Vec::new(),
            downscale_preset: "VGA (320px)".into(),
            shader: CRT_SHADERS.iter().position(|s| s.0 == "glow_gauss").unwrap_or(0),
            integer_scale: true,
            zoom: 1.0,
            pan: egui::Vec2::ZERO,
            compare: false,
            compare_x: 0.5,
            dragging_compare: false,
            animate: true,
            frame: 0,
            last_tick: Instant::now(),
            source_texture: None,
            source_pixels: None,
            original_size: None,
            video: None,
            video_frame: 0,
            playing: None,
            crop_enabled: false,
            crop: Crop::new(Ratio::SQUARE),
            crop_drag: None,
            seq: 0,
            sent: None,
            texture: None,
            shown_seq: 0,
            status: String::new(),
            error: None,
            export_open: false,
            export_format: export::Format::Mp4(Codec::H264),
            export_long_edge: 1920,
            export_quality: 1,
            export_loops: 1,
            export_snap: false,
            gif_width: 480,
            gif_fps: 12,
            still_seconds: 5.0,
            still_fps: 30,
            export_job: None,
            export_status: String::new(),
            still: None,
            source_path: None,
            snapshot: std::env::var_os("NTSCRT_UI_SNAPSHOT").map(PathBuf::from),
            snapshot_requested: false,
            snapshot_after: std::env::var("NTSCRT_SNAPSHOT_AFTER").ok().and_then(|v| v.parse().ok()).map(|s| (Instant::now(), s)),
            autoplay: std::env::var("NTSCRT_PLAY").as_deref() == Ok("1"),
            auto_export: std::env::var_os("NTSCRT_EXPORT").map(PathBuf::from),
        };
        let start = std::env::args_os().nth(1).map(PathBuf::from).or_else(|| std::env::var_os("NTSCRT_SOURCE").map(PathBuf::from));
        if let Some(p) = start {
            app.open(&p);
        }
        if let Some(p) = std::env::var_os("NTSCRT_LOOK") {
            app.load_look(Path::new(&p));
        }
        // NTSCRT_CROP=ratio[,x,y,zoom] and NTSCRT_COMPARE=1, for headless checks.
        if let Ok(spec) = std::env::var("NTSCRT_CROP") {
            let mut parts = spec.split(',');
            if let Some(r) = parts.next().and_then(Ratio::from_label) {
                let mut c = Crop::new(r);
                let mut next = || parts.next().and_then(|v| v.trim().parse::<f64>().ok());
                if let Some(x) = next() { c.x = x }
                if let Some(y) = next() { c.y = y }
                if let Some(z) = next() { c.scale = z }
                app.crop = c;
                app.crop_enabled = true;
            }
        }
        if std::env::var("NTSCRT_ANIMATE").as_deref() == Ok("0") {
            app.animate = false;
        }
        if let Some(p) = &app.auto_export {
            let ext = p.extension().map(|e| e.to_string_lossy().to_lowercase()).unwrap_or_default();
            app.export_format = match ext.as_str() {
                "png" => export::Format::Png,
                "gif" => export::Format::Gif,
                _ if std::env::var("NTSCRT_EXPORT_HEVC").as_deref() == Ok("1") => export::Format::Mp4(Codec::Hevc),
                _ => export::Format::Mp4(Codec::H264),
            };
            if let Some(n) = std::env::var("NTSCRT_EXPORT_LOOPS").ok().and_then(|v| v.parse().ok()) {
                app.export_loops = n;
            }
        }
        if std::env::var("NTSCRT_COMPARE").as_deref() == Ok("1") {
            app.compare = true;
            app.compare_x = 0.6;
        }
        app
    }

    fn open(&mut self, path: &Path) {
        let name = path.file_name().map(|n| n.to_string_lossy().into_owned()).unwrap_or_default();
        let ext = path.extension().map(|e| e.to_string_lossy().to_lowercase()).unwrap_or_default();
        self.sent = None;
        self.error = None;
        self.source_texture = None;
        self.source_pixels = None;
        self.source_path = Some(path.to_path_buf());
        self.still = None;
        if matches!(ext.as_str(), "mp4" | "mov" | "m4v") {
            // The worker opens it and reports its size (see Event::Opened).
            self.source = Some((name, 0, 0));
            self.original_size = None;
            self.video = None;
            self.playing = None;
            let _ = self.requests.send(Request::Video(path.to_path_buf()));
            return;
        }
        match image::open(path) {
            Ok(img) => {
                let img = img.to_rgba8();
                let (w, h) = img.dimensions();
                self.source = Some((name, w, h));
                self.original_size = Some((w, h));
                self.video = None;
                self.playing = None;
                let image = Image::new(w, h, img.into_raw());
                self.still = Some(image.clone());
                let _ = self.requests.send(Request::Still(image));
            }
            Err(e) => self.error = Some(format!("Couldn't open {}: {e}", path.display())),
        }
    }

    /// The picture the chain sees: the opened size, cropped.
    fn picture_size(&self) -> Option<(u32, u32)> {
        let (w, h) = self.original_size?;
        Some(if self.crop_enabled {
            let (_, _, cw, ch) = self.crop.rect(w, h);
            (cw, ch)
        } else {
            (w, h)
        })
    }

    fn crop_panel(&mut self, ui: &mut egui::Ui) {
        ui.checkbox(&mut self.crop_enabled, egui::RichText::new("Crop").heading())
            .on_hover_text("Cut the picture to an aspect ratio before anything else sees it. Drag the picture in the preview to move the crop.");
        if !self.crop_enabled {
            return;
        }
        let mut ratio_button = |ui: &mut egui::Ui, r: Ratio| {
            if ui.selectable_label(self.crop.ratio == r, r.label()).clicked() {
                self.crop = Crop::new(r);
            }
        };
        ui.horizontal(|ui| ratio_button(ui, Ratio::SQUARE));
        ui.horizontal(|ui| Ratio::PORTRAIT.into_iter().for_each(|r| ratio_button(ui, r)));
        ui.horizontal(|ui| Ratio::LANDSCAPE.into_iter().for_each(|r| ratio_button(ui, r)));
        let Some((w, h)) = self.original_size else { return };
        let (_, _, cw, ch) = self.crop.rect(w, h);
        if cw < w {
            ui.label("Left / right");
            ui.add(egui::Slider::new(&mut self.crop.x, 0.0..=1.0).show_value(false));
        }
        if ch < h {
            ui.label("Up / down");
            ui.add(egui::Slider::new(&mut self.crop.y, 0.0..=1.0).show_value(false));
        }
        ui.label("Zoom in");
        let mut pct = self.crop.scale * 100.0;
        if ui.add(egui::Slider::new(&mut pct, 100.0..=Crop::MAX_SCALE * 100.0).suffix("%").max_decimals(0)).changed() {
            self.crop.scale = pct / 100.0;
        }
        ui.horizontal(|ui| {
            ui.weak(format!("{cw} × {ch} of {w} × {h}"));
            if ui.small_button("Center").clicked() {
                (self.crop.x, self.crop.y) = (0.5, 0.5);
            }
        });
    }

    /// Load a look (the Mac app's preset JSON), as the Mac's `loadLook` does.
    fn load_look(&mut self, path: &Path) {
        let look = match std::fs::read_to_string(path).map_err(anyhow::Error::from).and_then(|j| Look::parse(&j)) {
            Ok(l) => l,
            Err(e) => {
                self.error = Some(format!("Couldn't load {}: {e:#}", path.display()));
                return;
            }
        };
        if let Some(c) = look.crop {
            self.crop = c;
            self.crop_enabled = true;
        }
        if let Some(v) = look.downscale_enabled { self.downscale = v }
        if let Some(v) = look.downscale_width { self.downscale_width = v }
        if let Some(v) = &look.downscale_preset { self.downscale_preset = v.clone() }
        if let Some(m) = look.downscale_method { self.method = m }
        if let Some(settings) = &look.ntsc_settings { self.ntsc_values = settings.clone() }
        if let Some(v) = look.ntsc_enabled { self.ntsc = v }
        if let Some(id) = &look.shader_preset {
            if let Some(i) = CRT_SHADERS.iter().position(|s| s.0 == id) {
                self.shader = i;
                // The shader's starting values with the look's on top.
                self.shader_params.remove(&i);
                self.shader_values.remove(&i);
                self.ensure_shader();
                if let Some(values) = self.shader_values.get_mut(&i) {
                    values.extend(look.shader_params.iter().map(|(k, v)| (k.clone(), *v)));
                }
            }
        }
        if let Some(v) = look.shader_enabled { self.crt = v }
        // A look with keyframes opens at its start (the Mac scrubs to 0).
        if let Some(first) = look.keys.first() {
            if let Some(values) = self.shader_values.get_mut(&self.shader) {
                values.extend(first.shader.iter().map(|(k, v)| (k.clone(), *v)));
            }
            if !first.ntsc.is_empty() {
                self.ntsc_values = first.ntsc.clone();
            }
        }
        self.look_notes = look.unported();
        self.look_name = path.file_stem().map(|n| n.to_string_lossy().into_owned());
        self.look_raw = Some(look.raw);
        self.error = None;
    }

    fn save_look(&mut self, path: &Path) {
        self.ensure_shader();
        let empty = HashMap::new();
        let json = write_look(
            self.look_raw.as_ref(),
            &LookState {
                downscale_enabled: self.downscale,
                downscale_width: self.downscale_width,
                downscale_preset: &self.downscale_preset,
                downscale_method: self.method,
                ntsc_enabled: self.ntsc,
                ntsc_settings: &self.ntsc_values,
                shader_enabled: self.crt,
                shader_preset: CRT_SHADERS[self.shader].0,
                shader_params: self.shader_values.get(&self.shader).unwrap_or(&empty),
                crop: self.crop_enabled.then_some(self.crop),
            },
        );
        match std::fs::write(path, json) {
            Ok(()) => self.look_name = path.file_stem().map(|n| n.to_string_lossy().into_owned()),
            Err(e) => self.error = Some(format!("Couldn't save {}: {e}", path.display())),
        }
    }

    fn preset_menu(&mut self, ui: &mut egui::Ui) {
        ui.menu_button("Preset", |ui| {
            if ui.button("Load…").clicked() {
                if let Some(p) = rfd::FileDialog::new().add_filter("Look", &["json"]).pick_file() {
                    self.load_look(&p);
                }
                ui.close();
            }
            if ui.button("Save…").clicked() {
                let name = format!("{}.json", self.look_name.as_deref().unwrap_or("Look"));
                if let Some(p) = rfd::FileDialog::new().add_filter("Look", &["json"]).set_file_name(name).save_file() {
                    self.save_look(&p);
                }
                ui.close();
            }
            if let Some(dir) = self.presets.clone() {
                ui.separator();
                let mut names: Vec<PathBuf> = std::fs::read_dir(&dir)
                    .map(|r| r.flatten().map(|e| e.path()).filter(|p| p.extension().is_some_and(|x| x == "json")).collect())
                    .unwrap_or_default();
                names.sort_by_key(|p| p.file_stem().map(|s| s.to_string_lossy().to_lowercase()));
                egui::ScrollArea::vertical().max_height(500.0).show(ui, |ui| {
                    for p in names {
                        let label = p.file_stem().map(|s| s.to_string_lossy().into_owned()).unwrap_or_default();
                        if ui.button(label).clicked() {
                            self.load_look(&p);
                            ui.close();
                        }
                    }
                });
            }
        });
    }

    /// The shader's parameters and values, loading them on first use: the
    /// preset's own values with the Mac's tweaks on top.
    fn ensure_shader(&mut self) {
        let Some(root) = &self.shaders else { return };
        let i = self.shader;
        if self.shader_params.contains_key(&i) {
            return;
        }
        let (id, _, rel) = CRT_SHADERS[i];
        let params = preset_parameters(&root.join(rel)).map_err(|e| format!("{e:#}"));
        if let Ok(ps) = &params {
            let mut values: HashMap<String, f32> = ps.iter().map(|p| (p.name.clone(), p.initial)).collect();
            values.extend(app_shader_defaults(id));
            self.shader_values.insert(i, values);
        }
        self.shader_params.insert(i, params);
    }

    fn reset_shader(&mut self) {
        self.shader_params.remove(&self.shader);
        self.shader_values.remove(&self.shader);
        self.ensure_shader();
    }

    fn input_height(&self) -> Option<u32> {
        let (_, w, h) = self.source.as_ref()?;
        Some(if self.downscale { DownscaleSpec::for_width(self.downscale_width, (*w, *h), self.method).height } else { *h })
    }

    fn settings(&self, source: (u32, u32)) -> Settings {
        let shader = match (&self.shaders, self.crt) {
            (Some(root), true) => {
                let (_, _, rel) = CRT_SHADERS[self.shader];
                let mut params: Vec<(String, f32)> =
                    self.shader_values.get(&self.shader).map(|v| v.iter().map(|(k, v)| (k.clone(), *v)).collect()).unwrap_or_default();
                params.sort_by(|a, b| a.0.cmp(&b.0));
                Some(ShaderSpec { preset: root.join(rel), params })
            }
            _ => None,
        };
        Settings {
            ntsc: self.ntsc.then(|| NtscSettings::Json(ntsc_values_json(&self.ntsc_values))),
            downscale: self.downscale.then(|| DownscaleSpec::for_width(self.downscale_width, source, self.method)),
            shader,
            // A clip's noise is seeded by its frame number + 1, as the Mac's
            // video export and PNG do; a still's by the Animate counter.
            frame: if self.video.is_some() { self.video_frame + 1 } else { self.frame },
        }
    }

    fn sidebar(&mut self, ui: &mut egui::Ui) {
        ui.with_layout(egui::Layout::bottom_up(egui::Align::LEFT), |ui| {
            ui.add_space(4.0);
            ui.weak(&self.status);
            ui.weak(format!("GPU: {}", self.adapter));
            ui.separator();
            ui.with_layout(egui::Layout::top_down(egui::Align::LEFT), |ui| {
                egui::ScrollArea::vertical().auto_shrink(false).show(ui, |ui| {
                    ui.set_max_width(SIDEBAR_WIDTH - 16.0);
                    self.sidebar_contents(ui);
                });
            });
        });
    }

    fn sidebar_contents(&mut self, ui: &mut egui::Ui) {
        // A fixed slider width: sizing sliders from the space available makes
        // the panel grow to fit them, which leaves more space, every frame
        // (the sidebar swallowed the window on Windows).
        ui.spacing_mut().slider_width = SIDEBAR_WIDTH - 120.0;
        ui.add_space(6.0);
        ui.heading("Source");
        ui.horizontal(|ui| {
            if ui.button("Open…").clicked() {
                if let Some(p) = rfd::FileDialog::new().add_filter("Images", &["png", "jpg", "jpeg"]).pick_file() {
                    self.open(&p);
                }
            }
        });
        match &self.source {
            Some((name, _, _)) => {
                ui.label(name);
                if let Some((w, h)) = self.original_size {
                    match self.video {
                        Some(v) => ui.weak(format!("{w} × {h} px · {} frames · {:.2} fps", v.total_frames, v.fps)),
                        None => ui.weak(format!("{w} × {h} px")),
                    };
                } else if self.error.is_none() {
                    ui.weak("Opening…");
                }
            }
            None => {
                ui.weak("Open an image, or drop one on the window.");
            }
        }
        ui.separator();
        self.crop_panel(ui);
        ui.separator();

        ui.checkbox(&mut self.downscale, egui::RichText::new("Downscale").heading());
        ui.add_enabled_ui(self.downscale, |ui| {
            ui.horizontal(|ui| {
                ui.label("Width");
                ui.add(egui::DragValue::new(&mut self.downscale_width).range(64..=1920).suffix(" px"));
            });
            if let Some((_, w, h)) = self.source {
                let spec = DownscaleSpec::for_width(self.downscale_width, (w, h), self.method);
                ui.weak(format!("Resolution: {} × {}", spec.width, spec.height));
            }
            ui.horizontal(|ui| {
                ui.label("Sampling");
                ui.selectable_value(&mut self.method, DownscaleMethod::Nearest, "Chunky")
                    .on_hover_text("One source pixel per block: hard pixel edges.");
                ui.selectable_value(&mut self.method, DownscaleMethod::Area, "Smooth")
                    .on_hover_text("The average of the whole block: softer, steady.");
            });
            if !matches!(self.method, DownscaleMethod::Nearest | DownscaleMethod::Area) {
                ui.weak(format!("Using {}, from the loaded preset.", self.method.display_name()));
            }
        });
        ui.separator();

        ui.horizontal(|ui| {
            ui.checkbox(&mut self.ntsc, egui::RichText::new("NTSC (TV)").heading());
            ui.with_layout(egui::Layout::right_to_left(egui::Align::Center), |ui| {
                if ui.small_button("Reset").on_hover_text("Back to the house look").clicked() {
                    self.ntsc_values = ntsc_default_values();
                }
            });
        });
        ui.add_enabled_ui(self.ntsc, |ui| {
            egui::CollapsingHeader::new("Settings").id_salt("ntsc-settings").default_open(true).show(ui, |ui| {
                ntsc_panel::controls(ui, &self.ntsc_settings, &mut self.ntsc_values);
            });
        });
        ui.separator();

        ui.horizontal(|ui| {
            ui.checkbox(&mut self.crt, egui::RichText::new("CRT").heading());
            ui.with_layout(egui::Layout::right_to_left(egui::Align::Center), |ui| {
                if ui.small_button("Reset").on_hover_text("This shader's parameters back to their starting values").clicked() {
                    self.reset_shader();
                }
            });
        });
        if self.shaders.is_none() {
            ui.colored_label(egui::Color32::LIGHT_RED, "Shaders not found (set NTSCRT_SHADERS).");
            return;
        }
        self.ensure_shader();
        let input_height = self.input_height();
        ui.add_enabled_ui(self.crt, |ui| {
            egui::ComboBox::from_id_salt("shader")
                .selected_text(CRT_SHADERS[self.shader].1)
                .show_ui(ui, |ui| {
                    for (i, s) in CRT_SHADERS.iter().enumerate() {
                        ui.selectable_value(&mut self.shader, i, s.1);
                    }
                });
            self.ensure_shader();
            let id = CRT_SHADERS[self.shader].0;
            match self.shader_params.get(&self.shader) {
                Some(Ok(params)) => {
                    let values = self.shader_values.entry(self.shader).or_default();
                    let (pre, sections) = shader_panel::sections(params);
                    ui.weak(format!("Parameters ({})", params.len()));
                    for p in pre {
                        shader_panel::control(ui, id, p, values, input_height);
                    }
                    for section in sections {
                        egui::CollapsingHeader::new(egui::RichText::new(&section.title).strong())
                            .id_salt(("shader-section", id, &section.title))
                            .default_open(true)
                            .show(ui, |ui| {
                                for p in section.params {
                                    shader_panel::control(ui, id, p, values, input_height);
                                }
                            });
                    }
                }
                Some(Err(e)) => {
                    ui.colored_label(egui::Color32::LIGHT_RED, e);
                }
                None => {}
            }
        });
    }

    fn palette(&mut self, ui: &mut egui::Ui) {
        // Its own backing: the preview behind it is near-black in either theme.
        let frame = egui::Frame::new().fill(ui.visuals().panel_fill).corner_radius(6.0).inner_margin(egui::Margin::symmetric(8, 3));
        if let Some(v) = self.video {
            frame.show(ui, |ui| ui.horizontal(|ui| {
                if ui.button(if self.playing.is_some() { "Pause" } else { "Play" }).on_hover_text("Space").clicked() {
                    self.toggle_play();
                }
                let mut f = self.video_frame;
                let last = v.total_frames.saturating_sub(1);
                ui.spacing_mut().slider_width = (ui.available_width() - 190.0).max(120.0);
                if ui.add(egui::Slider::new(&mut f, 0..=last).show_value(false)).changed() {
                    self.playing = None;
                    self.video_frame = f;
                }
                ui.monospace(format!("{}/{} · {:.2}s", self.video_frame + 1, v.total_frames, self.video_frame as f64 / v.timescale()));
            }));
            ui.add_space(4.0);
        }
        frame.show(ui, |ui| ui.horizontal(|ui| {
            ui.toggle_value(&mut self.compare, "Compare")
                .on_hover_text("Split the view: the full pipeline on the left, the original on the right. Drag the line to move the split.");
            ui.toggle_value(&mut self.integer_scale, "Integer scale")
                .on_hover_text("Snap the picture to whole-pixel multiples, for perfectly even scanlines.");
            ui.toggle_value(&mut self.animate, "Animate")
                .on_hover_text("Keep tape noise and jitter moving.");
            ui.separator();
            ui.label("Zoom");
            let mut pct = self.zoom * 100.0;
            if ui.add(egui::Slider::new(&mut pct, 100.0..=1200.0).suffix("%").max_decimals(0)).changed() {
                self.set_zoom(pct / 100.0);
            }
            if ui.button("Fit").on_hover_text("Back to 100% (or double-click the picture)").clicked() {
                self.set_zoom(1.0);
            }
            ui.weak("Alt/Ctrl-scroll to zoom; drag to pan.");
        }));
    }

    /// The chain input's size (for snapping exports onto the scanline grid).
    fn chain_input(&self) -> Option<(u32, u32)> {
        let (w, h) = self.picture_size()?;
        Some(if self.downscale {
            let d = DownscaleSpec::for_width(self.downscale_width, (w, h), self.method);
            (d.width, d.height)
        } else {
            (w, h)
        })
    }

    fn export_size(&self) -> Option<(u32, u32)> {
        let (w, h) = self.picture_size()?;
        let aspect = w as f64 / h.max(1) as f64;
        let snap = if self.export_snap { self.chain_input() } else { None };
        Some(match self.export_format {
            export::Format::Gif => ntscrt_engine::export::gif_size(self.gif_width, aspect, snap),
            _ => ntscrt_engine::export::video_size(self.export_long_edge, aspect, snap),
        })
    }

    fn export_window(&mut self, ctx: &egui::Context) {
        let mut open = self.export_open;
        egui::Window::new("Export").open(&mut open).resizable(false).collapsible(false).show(ctx, |ui| {
            use export::Format;
            ui.horizontal(|ui| {
                ui.label("Format");
                for (f, name) in [(Format::Png, "PNG"), (Format::Mp4(Codec::H264), "MP4 (H.264)"), (Format::Mp4(Codec::Hevc), "MP4 (HEVC)"), (Format::Gif, "GIF")] {
                    ui.selectable_value(&mut self.export_format, f, name);
                }
            });
            let video = self.video;
            match self.export_format {
                Format::Gif => {
                    ui.horizontal(|ui| {
                        ui.label("Width");
                        ui.add(egui::DragValue::new(&mut self.gif_width).range(64..=1920).suffix(" px"));
                        ui.label("Frame rate");
                        ui.add(egui::DragValue::new(&mut self.gif_fps).range(1..=50).suffix(" fps"));
                    });
                }
                _ => {
                    ui.horizontal(|ui| {
                        ui.label("Long edge");
                        ui.add(egui::DragValue::new(&mut self.export_long_edge).range(64..=4096).suffix(" px"));
                    });
                }
            }
            if let Format::Mp4(_) = self.export_format {
                ui.horizontal(|ui| {
                    ui.label("Quality");
                    for (i, (name, _)) in ntscrt_engine::export::QUALITIES.iter().enumerate() {
                        ui.selectable_value(&mut self.export_quality, i, *name);
                    }
                });
                if video.is_some() {
                    ui.horizontal(|ui| {
                        ui.label("Loop");
                        ui.add(egui::DragValue::new(&mut self.export_loops).range(1..=50).suffix("×"))
                            .on_hover_text("Repeat the clip inside the file, for places that don't loop video.");
                    });
                }
            }
            if video.is_none() && self.export_format != Format::Png {
                ui.horizontal(|ui| {
                    ui.label("Length");
                    ui.add(egui::DragValue::new(&mut self.still_seconds).range(0.5..=60.0).speed(0.1).suffix(" s"));
                    if let Format::Mp4(_) = self.export_format {
                        ui.add(egui::DragValue::new(&mut self.still_fps).range(1..=60).suffix(" fps"));
                    }
                });
            }
            ui.checkbox(&mut self.export_snap, "Snap size to scanline grid")
                .on_hover_text("Pick a nearby size where every scanline lands evenly. Without it, exports avoid banding by rendering larger and scaling down.");
            if let Some((w, h)) = self.export_size() {
                let mut line = format!("{w} × {h}");
                if self.export_format == Format::Gif {
                    let seconds = video.map_or(self.still_seconds, |v| v.duration);
                    let mb = 0.8 * (w * h) as f64 * (seconds * self.gif_fps as f64) / 1e6;
                    line += &format!(", about {mb:.1} MB");
                    if mb > 10.0 {
                        line += " (over 10 MB: many places won't take it)";
                    }
                }
                ui.weak(line);
            }
            ui.separator();
            match &self.export_job {
                Some((progress, _)) => {
                    let done = progress.done.load(std::sync::atomic::Ordering::Relaxed) as f32 / 1000.0;
                    ui.add(egui::ProgressBar::new(done).show_percentage());
                    if ui.button("Cancel").clicked() {
                        progress.cancel.store(true, std::sync::atomic::Ordering::Relaxed);
                    }
                    ctx.request_repaint_after(Duration::from_millis(100));
                }
                None => {
                    if ui.add_enabled(self.source.is_some() && self.original_size.is_some(), egui::Button::new("Export…")).clicked() {
                        self.start_export(None);
                    }
                }
            }
            if !self.export_status.is_empty() {
                ui.label(&self.export_status);
            }
        });
        self.export_open = open;
    }

    /// Start an export into `path`, or ask where.
    fn start_export(&mut self, path: Option<PathBuf>) {
        use export::Format;
        let (Some(size), Some(picture)) = (self.export_size(), self.picture_size()) else { return };
        let ext = match self.export_format {
            Format::Png => "png",
            Format::Mp4(_) => "mp4",
            Format::Gif => "gif",
        };
        let path = path.or_else(|| {
            let stem = self.source_path.as_ref().and_then(|p| p.file_stem()).map(|s| s.to_string_lossy().into_owned()).unwrap_or("NTSCRT".into());
            rfd::FileDialog::new().add_filter(ext.to_uppercase(), &[ext]).set_file_name(format!("{stem} NTSCRT.{ext}")).save_file()
        });
        let Some(path) = path else { return };
        let media = match (&self.still, &self.source_path, self.video) {
            (Some(img), _, None) => export::Media::Still(img.clone()),
            (_, Some(p), Some(_)) => export::Media::Video(p.clone()),
            _ => return,
        };
        let fps = self.video.map_or(self.still_fps as f64, |v| v.fps);
        let job = export::Job {
            format: self.export_format,
            path,
            size,
            media,
            crop: self.crop_enabled.then_some(self.crop),
            settings: self.settings(picture),
            png_frame: if self.video.is_some() { self.video_frame } else { self.frame },
            bitrate: ntscrt_engine::export::bitrate(size, fps, ntscrt_engine::export::QUALITIES[self.export_quality].1),
            loops: self.export_loops,
            still_seconds: self.still_seconds,
            still_fps: self.still_fps,
            gif_fps: self.gif_fps,
        };
        let progress = Arc::new(export::Progress::default());
        let (tx, rx) = channel();
        let p = progress.clone();
        std::thread::spawn(move || {
            let _ = tx.send(export::run(job, p).map_err(|e| format!("{e:#}")));
        });
        self.export_status = "Exporting…".into();
        self.export_job = Some((progress, rx));
    }

    fn toggle_play(&mut self) {
        self.playing = match self.playing {
            Some(_) => None,
            None => Some((Instant::now(), self.video_frame)),
        };
    }

    fn set_zoom(&mut self, z: f32) {
        self.zoom = z.clamp(1.0, 12.0);
        if self.zoom <= 1.0 {
            self.pan = egui::Vec2::ZERO;
        }
        self.clamp_pan();
    }

    /// Panning can't go past the picture's edge at the current zoom.
    fn clamp_pan(&mut self) {
        let half = (1.0 - 1.0 / self.zoom) * 0.5;
        self.pan = egui::vec2(self.pan.x.clamp(-half, half), self.pan.y.clamp(-half, half));
    }

    fn preview(&mut self, ui: &mut egui::Ui) {
        let Some((_, w, h)) = self.source else {
            ui.centered_and_justified(|ui| ui.label("Open an image (or drop one here) to start."));
            return;
        };
        let ctx = ui.ctx().clone();
        let full = ui.available_rect_before_wrap();
        let palette_h = if self.video.is_some() { 80.0 } else { 40.0 };
        let avail = egui::Rect::from_min_max(full.min, egui::pos2(full.max.x, full.max.y - palette_h));
        let mut palette_ui = ui.new_child(
            egui::UiBuilder::new().max_rect(egui::Rect::from_min_max(egui::pos2(full.min.x + 8.0, avail.max.y + 4.0), full.max)),
        );
        self.palette(&mut palette_ui);

        // The chain input's size: the Downscale's, else the picture's.
        let input = if self.downscale {
            let d = DownscaleSpec::for_width(self.downscale_width, (w, h), self.method);
            (d.width, d.height)
        } else {
            (w, h)
        };
        let ppp = ctx.pixels_per_point();
        let aspect = input.0 as f32 / input.1 as f32;
        let mut fit = avail.size();
        if fit.x / fit.y > aspect { fit.x = fit.y * aspect } else { fit.y = fit.x / aspect }
        let drawable = (((fit.x * ppp).floor() as u32).max(16), ((fit.y * ppp).floor() as u32).max(16));
        let plan = preview::plan(input, drawable, self.integer_scale);
        // The picture's rect: the display size in pixels, centered, on whole pixels.
        let center_px = avail.center().to_vec2() * ppp;
        let min_px = egui::vec2(
            (center_px.x - plan.display_width as f32 / 2.0).round(),
            (center_px.y - plan.display_height as f32 / 2.0).round(),
        );
        let target = egui::Rect::from_min_size(
            (min_px / ppp).to_pos2(),
            egui::vec2(plan.display_width as f32, plan.display_height as f32) / ppp,
        );
        let zoomed = self.zoom > 1.001;

        // Animate: the frame advances once the last one is on screen, at 30
        // frames a second with NTSC on and 60 without (the Mac's draw rates).
        if self.animate && self.video.is_none() {
            let interval = Duration::from_secs_f64(if self.ntsc { 1.0 / 30.0 } else { 1.0 / 60.0 });
            if self.shown_seq == self.seq && self.last_tick.elapsed() >= interval {
                self.frame = self.frame.wrapping_add(1);
                self.last_tick = Instant::now();
            }
            ctx.request_repaint_after(interval);
        }

        // Playback: the frame the clock says, dropping what rendering can't keep up with.
        if let (Some((since, from)), Some(v)) = (self.playing, self.video) {
            let f = from + (since.elapsed().as_secs_f64() * v.fps) as usize;
            self.video_frame = f % v.total_frames.max(1);
            ctx.request_repaint();
        }

        let settings = self.settings((w, h));
        let crop = self.crop_enabled.then_some(self.crop);
        let want = (settings, plan, zoomed, self.video_frame, crop, self.compare);
        // While playing, ask for the next frame once the last is on screen.
        let ready = self.playing.is_none() || self.shown_seq == self.seq;
        if self.sent.as_ref() != Some(&want) && ready {
            self.seq += 1;
            let _ = self.requests.send(Request::Render {
                seq: self.seq,
                settings: want.0.clone(),
                plan,
                full: zoomed,
                frame: self.video_frame,
                crop,
                want_source: self.compare,
            });
            self.sent = Some(want);
        }

        // What part of the picture is shown: all of it, or zoomed and panned.
        let uv = if zoomed {
            let c = egui::pos2(0.5 - self.pan.x, 0.5 - self.pan.y);
            let half = 0.5 / self.zoom;
            egui::Rect::from_min_max(egui::pos2(c.x - half, c.y - half), egui::pos2(c.x + half, c.y + half))
        } else {
            egui::Rect::from_min_max(egui::pos2(0.0, 0.0), egui::pos2(1.0, 1.0))
        };
        let painter = ui.painter_at(avail);
        if let Some(tex) = &self.texture {
            painter.image(tex.id(), target, uv, egui::Color32::WHITE);
        }
        if self.compare {
            if self.source_texture.is_none() {
                if let Some(img) = &self.source_pixels {
                    let color = egui::ColorImage::from_rgba_unmultiplied([img.width as usize, img.height as usize], &img.rgba);
                    self.source_texture = Some(ctx.load_texture("original", color, egui::TextureOptions::LINEAR));
                }
            }
            let x = target.left() + self.compare_x * target.width();
            if let Some(tex) = &self.source_texture {
                let right = egui::Rect::from_min_max(egui::pos2(x, target.top()), target.max);
                painter.with_clip_rect(right).image(tex.id(), target, uv, egui::Color32::WHITE);
            }
            painter.line_segment([egui::pos2(x, target.top()), egui::pos2(x, target.bottom())], egui::Stroke::new(1.0, egui::Color32::WHITE));
        }

        // Interaction: drag the compare line, drag to pan when zoomed,
        // Alt/Ctrl-scroll or pinch to zoom, double-click to fit.
        let response = ui.interact(avail, ui.scope_id().with("preview"), egui::Sense::click_and_drag());
        if response.drag_started() {
            if let Some(p) = response.interact_pointer_pos() {
                let x = target.left() + self.compare_x * target.width();
                self.dragging_compare = self.compare && (p.x - x).abs() < 8.0;
                self.crop_drag = Some((self.crop, p));
            }
        }
        if response.dragged() {
            if self.dragging_compare {
                if let Some(p) = response.interact_pointer_pos() {
                    self.compare_x = ((p.x - target.left()) / target.width()).clamp(0.0, 1.0);
                }
            } else if self.crop_enabled && !zoomed {
                // Drag the picture to move the crop: the picture follows the hand.
                if let (Some((ow, oh)), Some((start, from)), Some(p)) = (self.original_size, self.crop_drag, response.interact_pointer_pos()) {
                    let (x, y, cw, _) = start.rect(ow, oh);
                    // Source pixels per point on screen.
                    let k = cw as f32 / target.width();
                    let d = p - from;
                    self.crop = start.placed(x as f64 - (d.x * k) as f64, y as f64 - (d.y * k) as f64, cw as f64, ow, oh);
                }
            } else if zoomed {
                let d = response.drag_delta();
                self.pan += egui::vec2(d.x / target.width(), d.y / target.height()) / self.zoom;
                self.clamp_pan();
            }
        }
        if response.drag_stopped() {
            self.dragging_compare = false;
            self.crop_drag = None;
        }
        if response.double_clicked() {
            self.set_zoom(1.0);
        }
        if response.hovered() {
            let (scroll, pinch, modifier) = ctx.input(|i| (i.smooth_scroll_delta().y, i.zoom_delta(), i.modifiers.alt || i.modifiers.command));
            if pinch != 1.0 {
                self.set_zoom(self.zoom * pinch);
            } else if modifier && scroll != 0.0 {
                self.set_zoom(self.zoom * (1.0 + scroll * 0.005));
            }
        }
        if let Some(e) = &self.error {
            painter.text(avail.left_top() + egui::vec2(8.0, 8.0), egui::Align2::LEFT_TOP, e, egui::FontId::proportional(14.0), egui::Color32::LIGHT_RED);
        }
    }
}

impl eframe::App for App {
    fn ui(&mut self, ui: &mut egui::Ui, _frame: &mut eframe::Frame) {
        let ctx = ui.ctx().clone();
        let events: Vec<Event> = self.events.try_iter().collect();
        for e in events {
            let (seq, result, millis) = match e {
                Event::Adapter(a) => {
                    self.adapter = a;
                    continue;
                }
                Event::Opened(Ok(info)) => {
                    self.video = Some(info);
                    self.original_size = Some((info.width, info.height));
                    if let Some(src) = &mut self.source {
                        (src.1, src.2) = (info.width, info.height);
                    }
                    self.video_frame = 0;
                    if self.autoplay {
                        self.playing = Some((Instant::now(), 0));
                    }
                    continue;
                }
                Event::Opened(Err(e)) => {
                    self.error = Some(format!("Couldn't open the video: {e}"));
                    self.source = None;
                    continue;
                }
                Event::Rendered { seq, result, millis, source } => {
                    if let Some(src) = source {
                        self.source_pixels = Some(src);
                        self.source_texture = None;
                    }
                    (seq, result, millis)
                }
            };
            let r = Rendered { seq, result, millis };
            match r.result {
                Ok(img) => {
                    let color = egui::ColorImage::from_rgba_unmultiplied([img.width as usize, img.height as usize], &img.rgba);
                    match &mut self.texture {
                        Some(t) => t.set(color, egui::TextureOptions::NEAREST),
                        None => self.texture = Some(ctx.load_texture("preview", color, egui::TextureOptions::NEAREST)),
                    }
                    self.shown_seq = r.seq;
                    self.status = format!("{} × {}, rendered in {} ms", img.width, img.height, r.millis);
                    self.error = None;
                }
                Err(e) => self.error = Some(e),
            }
        }
        // The picture's size follows the crop.
        if let Some((w, h)) = self.picture_size() {
            if let Some(src) = &mut self.source {
                (src.1, src.2) = (w, h);
            }
        }
        if ctx.input(|i| i.key_pressed(egui::Key::Space)) && self.video.is_some() && !ctx.egui_wants_keyboard_input() {
            self.toggle_play();
        }
        let dropped = ctx.input(|i| i.raw.dropped_files.iter().map(|f| f.path().to_path_buf()).find(|p| !p.as_os_str().is_empty()));
        if let Some(p) = dropped {
            self.open(&p);
        }

        if let Some((_, rx)) = &self.export_job {
            if let Ok(r) = rx.try_recv() {
                self.export_status = match r {
                    Ok(m) => m,
                    Err(e) => format!("Export failed: {e}"),
                };
                self.export_job = None;
                if let Some(p) = self.auto_export.take() {
                    let _ = std::fs::write(p.with_extension("log"), &self.export_status);
                    ctx.send_viewport_cmd(egui::ViewportCommand::Close);
                }
            }
        }
        if let Some(p) = self.auto_export.clone() {
            if self.export_job.is_none() && self.shown_seq != 0 && self.shown_seq == self.seq {
                self.start_export(Some(p));
            }
            ctx.request_repaint_after(Duration::from_millis(50));
        }
        self.export_window(&ctx);
        egui::Panel::top("toolbar").show(ui, |ui| {
            ui.horizontal(|ui| {
                self.preset_menu(ui);
                if ui.button("Export…").clicked() {
                    self.export_open = true;
                }
                if let Some(name) = &self.look_name {
                    ui.label(name);
                }
                if !self.look_notes.is_empty() {
                    ui.colored_label(
                        egui::Color32::from_rgb(230, 150, 40),
                        format!("Not in the Windows version yet: {}", self.look_notes.join(", ")),
                    );
                }
            });
        });
        egui::Panel::left("sidebar").resizable(false).exact_size(SIDEBAR_WIDTH).show(ui, |ui| self.sidebar(ui));
        egui::CentralPanel::default()
            .frame(egui::Frame::NONE.fill(egui::Color32::from_rgb(13, 13, 15)))
            .show(ui, |ui| self.preview(ui));

        // NTSCRT_UI_SNAPSHOT: screenshot once the latest request is on screen.
        if let Some(path) = self.snapshot.clone() {
            let waited = self.snapshot_after.is_none_or(|(t, s)| t.elapsed().as_secs_f64() >= s);
            if !waited {
                ctx.request_repaint();
            }
            if waited && !self.snapshot_requested && self.shown_seq != 0 && self.shown_seq == self.seq {
                self.snapshot_requested = true;
                let close = ctx.clone();
                ctx.send_viewport_cmd(egui::ViewportCommand::Screenshot(egui::ScreenshotCallback::new(move |image| {
                    let [w, h] = image.size;
                    let rgba: Vec<u8> = image.pixels.iter().flat_map(|c| c.to_array()).collect();
                    if let Some(buf) = image::RgbaImage::from_raw(w as u32, h as u32, rgba) {
                        let _ = buf.save(&path);
                    }
                    close.send_viewport_cmd(egui::ViewportCommand::Close);
                    close.request_repaint();
                })));
            } else if self.error.is_some() && self.source.is_some() {
                eprintln!("error: {}", self.error.as_deref().unwrap_or_default());
                ctx.send_viewport_cmd(egui::ViewportCommand::Close);
            }
        }
    }
}

fn main() -> eframe::Result {
    let options = eframe::NativeOptions {
        viewport: egui::ViewportBuilder::default().with_title("NTSCRT (Windows preview)").with_inner_size([1200.0, 780.0]),
        ..Default::default()
    };
    eframe::run_native("NTSCRT", options, Box::new(|cc| Ok(Box::new(App::new(cc)))))
}
