//! NTSCRT for Windows — first skeleton: open a picture, NTSC on/off, the
//! Downscale, a CRT shader, and a live preview. Rendering runs on a worker
//! thread that owns the engine; the window shows the latest frame.
//!
//! Hooks (for checking it headlessly):
//! - `NTSCRT_SOURCE=<image>` (or a path argument): open it at launch.
//! - `NTSCRT_UI_SNAPSHOT=<png>`: once the first frame is on screen, save a
//!   screenshot of the window there and quit.

#![cfg_attr(not(debug_assertions), windows_subsystem = "windows")]

mod ntsc_panel;
mod shader_panel;

use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::sync::mpsc::{channel, Receiver, Sender};
use std::time::{Duration, Instant};

use eframe::egui;
use ntscrt_engine::serde_json::{Map, Value};
use ntscrt_engine::{
    app_shader_defaults, find_presets, find_shaders, write_look, Look, LookState, ntsc_default_values, ntsc_settings, ntsc_values_json, preset_parameters, DownscaleMethod,
    DownscaleSpec, Engine, Image, NtscSetting, NtscSettings, Settings, ShaderParam, ShaderSpec, CRT_SHADERS,
};
use ntscrt_engine::crop::{Crop, Ratio};
use ntscrt_engine::preview::{self, PreviewPlan};

const SIDEBAR_WIDTH: f32 = 330.0;

enum Request {
    Source(Image),
    Render { seq: u64, settings: Settings, plan: PreviewPlan, full: bool },
}

struct Rendered {
    seq: u64,
    result: Result<Image, String>,
    millis: u128,
}

fn worker(requests: Receiver<Request>, results: Sender<Rendered>, info: Sender<String>, ctx: egui::Context) {
    let mut engine = match Engine::new() {
        Ok(e) => e,
        Err(e) => {
            let _ = info.send(format!("No graphics device: {e}"));
            return;
        }
    };
    let a = engine.adapter_info();
    let _ = info.send(format!("{} ({:?})", a.name, a.backend));
    ctx.request_repaint();
    while let Ok(first) = requests.recv() {
        // Take everything waiting: new pictures in order, only the latest render.
        let mut render = None;
        for r in std::iter::once(first).chain(requests.try_iter()) {
            match r {
                Request::Source(img) => engine.set_source(img),
                r @ Request::Render { .. } => render = Some(r),
            }
        }
        if let Some(Request::Render { seq, settings, plan, full }) = render {
            let t = Instant::now();
            let result = engine.render_preview(&settings, plan, full).map_err(|e| format!("{e:#}"));
            let _ = results.send(Rendered { seq, result, millis: t.elapsed().as_millis() });
            ctx.request_repaint();
        }
    }
}

struct App {
    requests: Sender<Request>,
    results: Receiver<Rendered>,
    info: Receiver<String>,
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
    /// The picture as opened.
    original: Option<Image>,
    crop_enabled: bool,
    crop: Crop,
    /// The crop the engine's picture was made with.
    applied_crop: Option<Option<Crop>>,
    /// Dragging the picture: the crop and pointer where the drag began.
    crop_drag: Option<(Crop, egui::Pos2)>,

    seq: u64,
    sent: Option<(Settings, PreviewPlan, bool)>,
    texture: Option<egui::TextureHandle>,
    shown_seq: u64,
    status: String,
    error: Option<String>,

    snapshot: Option<PathBuf>,
    snapshot_requested: bool,
}

impl App {
    fn new(cc: &eframe::CreationContext) -> Self {
        let (req_tx, req_rx) = channel();
        let (res_tx, res_rx) = channel();
        let (info_tx, info_rx) = channel();
        let ctx = cc.egui_ctx.clone();
        std::thread::spawn(move || worker(req_rx, res_tx, info_tx, ctx));
        let mut app = Self {
            requests: req_tx,
            results: res_rx,
            info: info_rx,
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
            original: None,
            crop_enabled: false,
            crop: Crop::new(Ratio::SQUARE),
            applied_crop: None,
            crop_drag: None,
            seq: 0,
            sent: None,
            texture: None,
            shown_seq: 0,
            status: String::new(),
            error: None,
            snapshot: std::env::var_os("NTSCRT_UI_SNAPSHOT").map(PathBuf::from),
            snapshot_requested: false,
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
        if std::env::var("NTSCRT_COMPARE").as_deref() == Ok("1") {
            app.compare = true;
            app.compare_x = 0.6;
        }
        app
    }

    fn open(&mut self, path: &Path) {
        match image::open(path) {
            Ok(img) => {
                let img = img.to_rgba8();
                let (w, h) = img.dimensions();
                let name = path.file_name().map(|n| n.to_string_lossy().into_owned()).unwrap_or_default();
                self.source = Some((name, w, h));
                self.original = Some(Image::new(w, h, img.into_raw()));
                self.applied_crop = None;
                self.apply_source();
                self.sent = None;
                self.error = None;
            }
            Err(e) => self.error = Some(format!("Couldn't open {}: {e}", path.display())),
        }
    }

    /// Hand the engine the picture, cropped (the crop comes before anything
    /// else, as on the Mac).
    fn apply_source(&mut self) {
        let want = self.crop_enabled.then_some(self.crop);
        if self.applied_crop == Some(want) {
            return;
        }
        let Some(original) = &self.original else { return };
        let image = match want {
            Some(c) => c.apply(original),
            None => original.clone(),
        };
        if let Some(src) = &mut self.source {
            (src.1, src.2) = (image.width, image.height);
        }
        self.source_pixels = Some(image.clone());
        self.source_texture = None;
        let _ = self.requests.send(Request::Source(image));
        self.applied_crop = Some(want);
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
        let Some(original) = &self.original else { return };
        let (w, h) = (original.width, original.height);
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
            frame: self.frame,
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
                if let Some(o) = &self.original {
                    ui.weak(format!("{} × {} px", o.width, o.height));
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
        let palette_h = 40.0;
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
        if self.animate {
            let interval = Duration::from_secs_f64(if self.ntsc { 1.0 / 30.0 } else { 1.0 / 60.0 });
            if self.shown_seq == self.seq && self.last_tick.elapsed() >= interval {
                self.frame = self.frame.wrapping_add(1);
                self.last_tick = Instant::now();
            }
            ctx.request_repaint_after(interval);
        }

        let settings = self.settings((w, h));
        let want = (settings, plan, zoomed);
        if self.sent.as_ref() != Some(&want) {
            self.seq += 1;
            let _ = self.requests.send(Request::Render { seq: self.seq, settings: want.0.clone(), plan, full: zoomed });
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
                if let (Some(original), Some((start, from)), Some(p)) = (&self.original, self.crop_drag, response.interact_pointer_pos()) {
                    let (ow, oh) = (original.width, original.height);
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
        for a in self.info.try_iter() {
            self.adapter = a;
        }
        for r in self.results.try_iter() {
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
        self.apply_source();
        let dropped = ctx.input(|i| i.raw.dropped_files.iter().map(|f| f.path().to_path_buf()).find(|p| !p.as_os_str().is_empty()));
        if let Some(p) = dropped {
            self.open(&p);
        }

        egui::Panel::top("toolbar").show(ui, |ui| {
            ui.horizontal(|ui| {
                self.preset_menu(ui);
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
            if !self.snapshot_requested && self.shown_seq != 0 && self.shown_seq == self.seq {
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
